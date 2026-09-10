//
//  ExtensionRuntime.swift
//  MangaCarta
//
//  The thing that actually runs an Extension: one `JSContext` per invocation, the
//  message contract from the Host API design's "Configuration-first Sources" and
//  "Envelope and value rules" sections, and the cancellation semantics of
//  "Scheduling, budgets, and cancellation".
//
//  ## Isolation, decided rather than inherited
//
//  `JSContext` is not `Sendable` and JavaScriptCore is not safe to touch from two
//  threads at once. So every JavaScript touch in this file — creating the context,
//  evaluating the bundle, calling the engine, converting a value, delivering a host
//  callback — happens on one serial `DispatchQueue` owned by that invocation, and no
//  `JSValue` ever leaves it. `ExtensionHostCall.deliver` is the single door a
//  capability uses to get back in, and it hops onto that queue for the caller.
//
//  The queue is **per invocation, not per runtime**. JavaScriptCore offers no App
//  Store-safe way to interrupt a running script — `JSContextGroupSetExecutionTimeLimit`
//  is SPI — so a runaway engine cannot be preempted. Giving it its own queue means it
//  wedges only itself; a shared queue would let one Source stall every other. This is
//  also why "destroys an uncooperative JavaScript context" below means *the host lets
//  the context go and refuses every later callback*, which is the strongest thing the
//  public API can promise. The design's first open evidence gate covers the script-time
//  budget that would otherwise catch such an engine, and it is not settled here.
//
//  ## What this file does not do
//
//  It does not implement `host.http`, `host.storage`, `host.log` or `host.browser` —
//  those are separate capabilities that plug in through `ExtensionHostCapability`. It
//  does not validate domain shapes either: `ExtensionDomainValidator` owns that, and it
//  runs on the JSON this bridge produces.
//

import Foundation
import JavaScriptCore

// MARK: - Errors

/// A failure that ends one invocation, in the design's stable "Errors and partial
/// success" taxonomy. `invocationID` is the id that section requires every error to
/// carry so a log line can be traced back.
struct ExtensionInvocationError: Error, Equatable {
    let code: ExtensionHostErrorCode
    let message: String?
    let retryAfterSeconds: Double?
    let details: JSONValue?
    let invocationID: UUID

    init(code: ExtensionHostErrorCode,
         message: String? = nil,
         retryAfterSeconds: Double? = nil,
         details: JSONValue? = nil,
         invocationID: UUID) {
        self.code = code
        self.message = message
        self.retryAfterSeconds = retryAfterSeconds
        self.details = details
        self.invocationID = invocationID
    }
}

// MARK: - Cancellation

/// "Every invocation has one host cancellation signal." Cancelling is idempotent and
/// safe from any thread; a token cancelled before `invoke` is called stops the
/// invocation before any Extension code is evaluated.
final class ExtensionCancellationToken {

    private let lock = NSLock()
    private var cancelled = false
    private var handlers: [() -> Void] = []

    init() {}

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true
        let pending = handlers
        handlers = []
        lock.unlock()
        pending.forEach { $0() }
    }

    /// Runs `handler` at most once — immediately if the token is already cancelled.
    func onCancel(_ handler: @escaping () -> Void) {
        lock.lock()
        if cancelled {
            lock.unlock()
            handler()
            return
        }
        handlers.append(handler)
        lock.unlock()
    }
}

// MARK: - Host capability seam

/// One member of `context.host`.
///
/// The design's `context` shape names `http`, `browser`, `storage` and `log`; each is
/// a separate implementation of this protocol, and "Versions and feature negotiation"
/// makes an absent optional capability simply absent from `context.host`. This runtime
/// installs exactly the capabilities it is given and invents none.
protocol ExtensionHostCapability: AnyObject {
    /// The key under `context.host`, which is also the negotiated feature name.
    var hostName: String { get }

    /// Builds the value installed at `context.host[hostName]`.
    ///
    /// Called on the invocation's queue, once, before the engine runs. Returning `nil`
    /// omits the capability rather than installing a broken one. Every asynchronous
    /// call the returned value starts must go through `scope.admitHostCall(onCancel:)`,
    /// and every result must come back through the returned `ExtensionHostCall`.
    ///
    /// The context is a parameter rather than something the scope vends, because it is
    /// valid only here and inside a `deliver` body. A capability that outlives its
    /// invocation — S5's do, they are held by their own services — must have no way to
    /// reach a context the host has already released.
    func makeHostValue(in context: JSContext, scope: ExtensionInvocationScope) -> JSValue?
}

/// One admitted asynchronous host-capability call.
///
/// Holding a call is what keeps a capability entitled to re-enter JavaScript. After
/// cancellation the entitlement is gone: `deliver` runs nothing and reports `false`.
final class ExtensionHostCall {

    fileprivate let identifier = UUID()
    fileprivate let onCancel: (() -> Void)?
    private weak var invocation: ExtensionInvocation?

    fileprivate init(invocation: ExtensionInvocation, onCancel: (() -> Void)?) {
        self.invocation = invocation
        self.onCancel = onCancel
    }

    /// Delivers a capability result back into JavaScript.
    ///
    /// Safe to call from any thread. `body` runs on the invocation's queue and only
    /// while the invocation is live; once cancelled it is **discarded** — the design's
    /// word — and this returns `false`. A capability that ignores the return value
    /// still cannot change invocation state, which is the point.
    @discardableResult
    func deliver(_ body: @escaping (JSContext) -> Void) -> Bool {
        guard let invocation else { return false }
        return invocation.deliver(callID: identifier, body: body)
    }
}

/// What a capability is given when it is installed. It is the capability's only handle
/// on the invocation, and deliberately exposes no way to settle the result: only the
/// engine's own returned envelope does that.
final class ExtensionInvocationScope {

    let invocationID: UUID
    let sourceID: QualifiedSourceID
    let operation: SourceOperation
    let hostAPIVersion: HostAPIVersion
    let network: NetworkPolicy
    /// Converts values for this invocation's context. Use it only on the invocation's
    /// queue, with `JSValue`s from that context — inside `makeHostValue` or a `deliver`
    /// body — which is the only time the context it reads is alive.
    let bridge: ExtensionJSBridge

    private weak var invocation: ExtensionInvocation?

    fileprivate init(invocation: ExtensionInvocation,
                     bridge: ExtensionJSBridge,
                     declaration: SourceDeclaration,
                     operation: SourceOperation) {
        self.invocation = invocation
        self.bridge = bridge
        invocationID = invocation.invocationID
        sourceID = declaration.qualifiedId
        hostAPIVersion = declaration.selectedHostAPIVersion
        network = declaration.network
        self.operation = operation
    }

    var isCancelled: Bool { invocation?.isCancelled ?? true }

    /// Admits an asynchronous host-capability call.
    ///
    /// Returns `nil` once the invocation is cancelled — "no new host-capability call is
    /// accepted" — in which case the capability must start no work. `onCancel` runs
    /// once if cancellation arrives while the call is outstanding, and is where a
    /// capability cancels its `URLSession` task or drops a queued request.
    func admitHostCall(onCancel: (() -> Void)?) -> ExtensionHostCall? {
        invocation?.admitHostCall(onCancel: onCancel)
    }

    /// Reads `context.signal.aborted` from the invocation's own context, on its queue.
    /// A capability has no reason to need this; the tests for criterion 7 do.
    func readsSignalAbortedForTesting() -> Bool? {
        invocation?.readSignalAborted()
    }
}

// MARK: - The invocation

/// One invocation's mutable state, all of it behind `queue`.
private final class ExtensionInvocation {

    let invocationID = UUID()
    let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Void>()

    private var context: JSContext?
    private var cancelled = false
    private var settled = false
    private var tornDown = false
    private var liveCalls: [UUID: ExtensionHostCall] = [:]
    private var signal: JSValue?
    private var continuation: CheckedContinuation<Any, Error>?

    init() {
        queue = DispatchQueue(label: "com.mangacarta.extension-runtime.\(invocationID.uuidString)")
        queue.setSpecific(key: queueKey, value: ())
    }

    private var isOnQueue: Bool { DispatchQueue.getSpecific(key: queueKey) != nil }

    private func onQueue<T>(_ body: () -> T) -> T {
        isOnQueue ? body() : queue.sync(execute: body)
    }

    var isCancelled: Bool { onQueue { cancelled } }

    var activeContext: JSContext? { onQueue { context } }

    func adopt(context: JSContext, signal: JSValue?) {
        self.context = context
        self.signal = signal
    }

    func attach(_ continuation: CheckedContinuation<Any, Error>) {
        self.continuation = continuation
    }

    // MARK: Settling

    /// Settles the invocation exactly once. Everything that arrives afterwards — a late
    /// promise resolution, a late capability callback — finds `settled` already true
    /// and changes nothing.
    func settle(_ result: Result<Any, Error>) {
        guard !settled else { return }
        settled = true
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }

    var isSettled: Bool { settled }

    // MARK: Host calls

    func admitHostCall(onCancel: (() -> Void)?) -> ExtensionHostCall? {
        onQueue {
            guard !cancelled, !tornDown else { return nil }
            let call = ExtensionHostCall(invocation: self, onCancel: onCancel)
            liveCalls[call.identifier] = call
            return call
        }
    }

    func deliver(callID: UUID, body: @escaping (JSContext) -> Void) -> Bool {
        onQueue {
            guard !cancelled, !tornDown, let context, liveCalls[callID] != nil else {
                return false
            }
            liveCalls.removeValue(forKey: callID)
            body(context)
            return true
        }
    }

    // MARK: Cancellation

    /// The design's cancellation, in its own order: refuse new calls, remove queued
    /// ones and tell them to stop, flip the engine's signal, settle as `cancelled`, and
    /// schedule the context's destruction after the grace period.
    func cancel(gracePeriod: TimeInterval, invocationID: UUID) {
        queue.async { [self] in
            guard !cancelled else { return }
            cancelled = true

            let outstanding = liveCalls.values
            liveCalls.removeAll()
            outstanding.forEach { $0.onCancel?() }

            signal?.setObject(true, forKeyedSubscript: "__aborted" as NSString)
            settle(.failure(ExtensionInvocationError(code: .cancelled,
                                                     message: "the invocation was cancelled",
                                                     invocationID: invocationID)))

            queue.asyncAfter(deadline: .now() + gracePeriod) { [self] in
                tearDown()
            }
        }
    }

    /// Releases the context. A still-running script cannot be interrupted, but nothing
    /// it does afterwards can reach the host: `deliver` refuses, and the engine's
    /// resolver is no longer wired to anything.
    func tearDown() {
        guard !tornDown else { return }
        tornDown = true
        liveCalls.removeAll()
        signal = nil
        context = nil
    }

    func readSignalAborted() -> Bool? {
        onQueue {
            signal?.forProperty("aborted")?.toBool()
        }
    }
}

// MARK: - The runtime

/// Runs one Source's engine.
///
/// A runtime is bound to one validated `SourceDeclaration` and one bundle script, and
/// creates a fresh `JSContext` for every invocation — so nothing an engine leaves on
/// `globalThis` survives into the next call, and an engine has no reach into any other
/// Source's configuration or state.
final class ExtensionRuntime {

    /// The prelude runs before the bundle, and everything it needs is captured while
    /// the builtins are still pristine. `adopt` binds `Promise.resolve` and
    /// `Promise.prototype.then` at that moment, so an engine that later reassigns
    /// either one cannot change how its own result is awaited. `signal` carries a live
    /// getter rather than a snapshot, so an engine reads the current state.
    private static let prelude = """
        globalThis.__mangacartaPrelude = (function () {
          var resolve = Promise.resolve.bind(Promise);
          var then = Function.prototype.call.bind(Promise.prototype.then);
          var defineProperty = Object.defineProperty;
          return {
            adopt: function (value, onFulfilled, onRejected) {
              then(resolve(value), onFulfilled, onRejected);
            },
            makeSignal: function () {
              var state = { __aborted: false };
              defineProperty(state, "aborted", {
                get: function () { return this.__aborted === true; }, enumerable: false
              });
              state.throwIfAborted = function () {
                if (this.__aborted === true) {
                  var error = new Error("cancelled");
                  error.hostErrorCode = "cancelled";
                  throw error;
                }
              };
              return state;
            }
          };
        })();
        """

    private let bundleScript: String
    private let declaration: SourceDeclaration
    private let capabilities: [ExtensionHostCapability]
    private let gracePeriod: TimeInterval

    private let stateLock = NSLock()
    private var evaluatedBundle = false
    private var current: ExtensionInvocation?

    init(bundleScript: String,
         declaration: SourceDeclaration,
         capabilities: [ExtensionHostCapability] = [],
         cancellationGracePeriod: TimeInterval = 0.25) {
        self.bundleScript = bundleScript
        self.declaration = declaration
        self.capabilities = capabilities
        gracePeriod = cancellationGracePeriod
    }

    /// True once Extension code has been evaluated at least once. A refusal that
    /// happens before invocation — an undeclared capability, an already-cancelled
    /// token — must leave this `false`.
    var didEvaluateBundle: Bool { stateLock.withLock { evaluatedBundle } }

    /// The most recent invocation's context, or `nil` once it has been released. This
    /// is how the destruction the design requires after the cancellation grace period
    /// is observable at all.
    var activeContext: JSContext? { stateLock.withLock { current }?.activeContext }

    /// Invokes one declared operation.
    ///
    /// Throws `ExtensionInvocationError`; the value returned on success is the
    /// envelope's `value`, already JSON-shaped Foundation, ready for
    /// `ExtensionDomainValidator`.
    func invoke(_ operation: SourceOperation,
                request: [String: Any],
                cancellation: ExtensionCancellationToken = ExtensionCancellationToken())
    async throws -> Any {
        let invocation = ExtensionInvocation()
        stateLock.withLock { current = invocation }
        let identity = invocation.invocationID

        // "The runtime calls only declared capabilities": asking for an undeclared one
        // is a host bug, caught before any Extension code is evaluated.
        guard declaration.capabilities.supports(operation) else {
            throw ExtensionInvocationError(
                code: .invalidRequest,
                message: "\(operation.rawValue) is not a declared capability of this Source",
                invocationID: identity)
        }
        guard !cancellation.isCancelled else {
            throw ExtensionInvocationError(code: .cancelled,
                                           message: "the invocation was cancelled",
                                           invocationID: identity)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                invocation.queue.async { [self] in
                    invocation.attach(continuation)
                    cancellation.onCancel { [weak invocation] in
                        invocation?.cancel(gracePeriod: gracePeriod, invocationID: identity)
                    }
                    start(operation, request: request, invocation: invocation)
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    // MARK: - One invocation, on its own queue

    private func start(_ operation: SourceOperation,
                       request: [String: Any],
                       invocation: ExtensionInvocation) {
        guard !invocation.isCancelled else { return }
        let identity = invocation.invocationID

        guard let context = JSContext(virtualMachine: JSVirtualMachine()),
              let bridge = ExtensionJSBridge(context: context) else {
            invocation.settle(.failure(ExtensionInvocationError(
                code: .script, message: "the JavaScript context could not be created",
                invocationID: identity)))
            return
        }
        context.exceptionHandler = { context, exception in context?.exception = exception }

        context.evaluateScript(Self.prelude)
        guard let prelude = context.objectForKeyedSubscript("__mangacartaPrelude"),
              let adopt = prelude.forProperty("adopt"),
              let signal = prelude.forProperty("makeSignal")?.call(withArguments: []) else {
            invocation.settle(.failure(ExtensionInvocationError(
                code: .script, message: "the host prelude did not install",
                invocationID: identity)))
            return
        }
        context.globalObject?.deleteProperty("__mangacartaPrelude")
        invocation.adopt(context: context, signal: signal)

        var engineRegistry: [String: JSValue] = [:]
        let register: @convention(block) (JSValue, JSValue) -> Void = { name, engine in
            guard let key = name.toString(), !key.isEmpty else { return }
            engineRegistry[key] = engine
        }
        context.setObject(register, forKeyedSubscript: "registerEngine" as NSString)

        stateLock.withLock { evaluatedBundle = true }
        context.evaluateScript(bundleScript)
        context.globalObject?.deleteProperty("registerEngine")
        if let exception = context.exception {
            context.exception = nil
            invocation.settle(.failure(scriptError(exception, invocationID: identity)))
            return
        }

        guard let engine = engineRegistry[declaration.engine], engine.isObject,
              let entry = engine.forProperty("invoke"), entry.hasFunctionValue else {
            invocation.settle(.failure(ExtensionInvocationError(
                code: .unsupported,
                message: "the bundle registers no engine named \(declaration.engine) "
                    + "with an invoke function",
                invocationID: identity)))
            return
        }

        let scope = ExtensionInvocationScope(invocation: invocation,
                                             bridge: bridge,
                                             declaration: declaration,
                                             operation: operation)
        do {
            let arguments = try invocationArguments(scope: scope,
                                                    in: context,
                                                    request: request,
                                                    signal: signal)
            guard let returned = entry.call(withArguments: arguments),
                  context.exception == nil else {
                let exception = context.exception
                context.exception = nil
                invocation.settle(.failure(scriptError(exception, invocationID: identity)))
                return
            }
            adoptResult(returned,
                        using: adopt,
                        invocation: invocation,
                        context: context,
                        bridge: bridge)
        } catch let error as ExtensionSchemaError {
            invocation.settle(.failure(ExtensionInvocationError(
                code: error.code, message: error.errorDescription, invocationID: identity)))
        } catch {
            invocation.settle(.failure(ExtensionInvocationError(
                code: .invalidRequest, message: "\(error)", invocationID: identity)))
        }
    }

    /// Builds the two values the engine is handed: its frozen request, and the
    /// `{ source, host, signal }` context the design's "Configuration-first Sources"
    /// section specifies. Nothing else is reachable — there is no registry object and
    /// no second Source anywhere in this context.
    private func invocationArguments(scope: ExtensionInvocationScope,
                                     in context: JSContext,
                                     request: [String: Any],
                                     signal: JSValue) throws -> [Any] {
        let bridge = scope.bridge

        let host = JSValue(newObjectIn: context)
        for capability in capabilities {
            guard let value = capability.makeHostValue(in: context, scope: scope) else { continue }
            host?.setObject(value, forKeyedSubscript: capability.hostName as NSString)
        }

        let source = JSValue(newObjectIn: context)
        source?.setObject(declaration.qualifiedId.rawValue,
                          forKeyedSubscript: "id" as NSString)
        source?.setObject(try bridge.frozenValue(from: declaration.configuration.foundationValue),
                          forKeyedSubscript: "configuration" as NSString)
        source?.setObject(try bridge.frozenValue(from: [
            "mode": declaration.languages.mode.rawValue,
            "values": declaration.languages.tags
        ]), forKeyedSubscript: "languages" as NSString)

        let invocationContext = JSValue(newObjectIn: context)
        invocationContext?.setObject(source, forKeyedSubscript: "source" as NSString)
        invocationContext?.setObject(host, forKeyedSubscript: "host" as NSString)
        invocationContext?.setObject(signal, forKeyedSubscript: "signal" as NSString)

        return [scope.operation.rawValue,
                try bridge.frozenValue(from: request),
                invocationContext as Any]
    }

    /// Adopts the engine's return value through the prelude's bound `Promise.resolve`
    /// and `Promise.prototype.then`, so a plain value and a thenable settle through
    /// exactly one path and neither can be redirected by reassigning `Promise`.
    private func adoptResult(_ returned: JSValue,
                             using adopt: JSValue,
                             invocation: ExtensionInvocation,
                             context: JSContext,
                             bridge: ExtensionJSBridge) {
        let identity = invocation.invocationID
        let fulfil: @convention(block) (JSValue) -> Void = { [weak invocation] value in
            guard let invocation, !invocation.isCancelled, !invocation.isSettled else { return }
            invocation.settle(Self.envelope(value, bridge: bridge, invocationID: identity))
        }
        let reject: @convention(block) (JSValue) -> Void = { [weak invocation] reason in
            guard let invocation, !invocation.isCancelled, !invocation.isSettled else { return }
            invocation.settle(.failure(Self.scriptError(reason, invocationID: identity)))
        }

        _ = adopt.call(withArguments: [returned,
                                       JSValue(object: fulfil, in: context) as Any,
                                       JSValue(object: reject, in: context) as Any])
        if let exception = context.exception {
            context.exception = nil
            invocation.settle(.failure(scriptError(exception, invocationID: identity)))
        }
    }

    // MARK: - The envelope

    /// "Every operation result crosses in one envelope." Nothing about the envelope is
    /// optional or inferred: an object without a boolean `ok` is not a result. The
    /// whole envelope crosses the pre-conversion boundary first, so a function or a
    /// typed array buried in `value` is refused here rather than reaching the domain
    /// validator disguised as data.
    private static func envelope(_ value: JSValue,
                                 bridge: ExtensionJSBridge,
                                 invocationID: UUID) -> Result<Any, Error> {
        let converted: Any
        do {
            converted = try bridge.jsonValue(from: value, path: "result")
        } catch let error as ExtensionSchemaError {
            return .failure(ExtensionInvocationError(code: error.code,
                                                     message: error.errorDescription,
                                                     invocationID: invocationID))
        } catch {
            return .failure(invalidResponse("\(error)", invocationID))
        }

        guard let object = converted as? [String: Any] else {
            return .failure(invalidResponse("the result envelope is not an object", invocationID))
        }
        guard let flag = object["ok"] as? NSNumber,
              CFGetTypeID(flag) == CFBooleanGetTypeID() else {
            return .failure(invalidResponse("the result envelope has no boolean `ok`",
                                            invocationID))
        }
        guard flag.boolValue else {
            return .failure(failure(from: object["error"], invocationID: invocationID))
        }
        guard let payload = object["value"] else {
            return .failure(invalidResponse("a successful result envelope carries no `value`",
                                            invocationID))
        }
        return .success(payload)
    }

    private static func failure(from raw: Any?, invocationID: UUID) -> ExtensionInvocationError {
        guard let failure = raw as? [String: Any] else {
            return invalidResponse("a failed result envelope carries no `error` object",
                                   invocationID)
        }
        guard let rawCode = failure["code"] as? String,
              let code = ExtensionHostErrorCode(rawValue: rawCode) else {
            return invalidResponse(
                "the result envelope's error code is not part of the Host API taxonomy",
                invocationID)
        }
        var retryAfter: Double?
        if let seconds = failure["retryAfterSeconds"] as? NSNumber,
           CFGetTypeID(seconds) != CFBooleanGetTypeID() {
            retryAfter = seconds.doubleValue
        }
        return ExtensionInvocationError(
            code: code,
            message: failure["message"] as? String,
            retryAfterSeconds: retryAfter,
            details: failure["details"].flatMap(JSONValue.init(converting:)),
            invocationID: invocationID)
    }

    private static func invalidResponse(_ reason: String,
                                        _ invocationID: UUID) -> ExtensionInvocationError {
        ExtensionInvocationError(code: .invalidResponse, message: reason,
                                 invocationID: invocationID)
    }

    /// A thrown or rejected JavaScript value. The design's taxonomy calls this `script`
    /// — "page-context or engine script failed" — and its message is diagnostic only:
    /// "Extension `message` is diagnostic and never shown verbatim."
    private static func scriptError(_ reason: JSValue?, invocationID: UUID) -> ExtensionInvocationError {
        var message = "the engine raised an error"
        if let reason, !reason.isUndefined, !reason.isNull {
            let described = reason.isObject
                ? (reason.forProperty("message")?.toString() ?? reason.toString())
                : reason.toString()
            if let described, !described.isEmpty { message = described }
        }
        return ExtensionInvocationError(code: .script, message: message,
                                        invocationID: invocationID)
    }

    private func scriptError(_ reason: JSValue?, invocationID: UUID) -> ExtensionInvocationError {
        Self.scriptError(reason, invocationID: invocationID)
    }
}

// MARK: - Small bridges between the Wave 1 types and dynamic values

private extension JSValue {
    /// `isObject` is true for functions too, so "is this callable" needs its own test.
    var hasFunctionValue: Bool {
        guard isObject, let ref = jsValueRef,
              let object = JSValueToObject(context.jsGlobalContextRef, ref, nil) else {
            return false
        }
        return JSObjectIsFunction(context.jsGlobalContextRef, object)
    }
}

extension JSONValue {

    /// The Foundation shape this value takes on the way into a context.
    ///
    /// Defers to `HostJSONValueConverter` so the runtime and the host capabilities agree
    /// on which values may cross the extension boundary. This used to be a second,
    /// laxer implementation: it could not fail, so an integer past 2^53 went into a
    /// context silently widened to a double, while the same value through a host
    /// capability was refused.
    var foundationValue: Any {
        get throws { try HostJSONValueConverter.foundationValue(self) }
    }

    /// Reads JSON-shaped Foundation back into the closed enum, so a value that crossed
    /// the bridge can be compared and stored. Returns `nil` for anything the bridge
    /// would not have produced.
    ///
    /// The `nil` shape is kept deliberately: the one caller formats error details, where
    /// throwing would be perverse. Only the *rules* are shared, via
    /// `HostJSONValueConverter` — the failure style stays local to the call site.
    init?(converting value: Any) {
        guard let converted = try? HostJSONValueConverter.convert(value) else { return nil }
        self = converted
    }
}
