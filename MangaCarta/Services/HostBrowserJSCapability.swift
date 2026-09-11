//
//  HostBrowserJSCapability.swift
//  MangaCarta
//
//  The seam between S4's JavaScript-facing `ExtensionHostCapability` protocol and S5's
//  typed `HostBrowserCapability`. S4 shipped the protocol and S5 shipped the Swift
//  capability, but nothing on `main` installed one as the other — an engine had no
//  `context.host.browser` to call. This file is that adapter, and it is additive: it
//  changes no public API either slice shipped.
//
//  The JavaScript shape is the design's "Browser extraction" signature exactly:
//
//      host.browser.extract({ url, script, interaction = "allowForeground" })
//        -> Promise<{ value, finalURL, warnings }>
//
//  Three rules this file exists to keep:
//
//  * **Every asynchronous call is admitted.** Work starts only if
//    `scope.admitHostCall` hands back a call, and results return only through that
//    call's `deliver`. After cancellation the entitlement is gone and a late browser
//    result changes nothing — acceptance criterion 7, enforced here rather than
//    assumed.
//  * **The promise is built from the context's own `Promise`.** `resolve`/`reject` are
//    captured while the executor runs, and are touched only inside a `deliver` body,
//    which is the only time the invocation's context is alive and on its queue.
//  * **Failures reject with a Host API error code.** The engine reads
//    `error.hostErrorCode` and puts it straight into its rejected envelope, so the
//    taxonomy survives the round trip instead of collapsing into `script`.
//

import Foundation
import JavaScriptCore

/// What `host.browser.extract` needs from the host. `HostBrowserCapability` is the
/// production conformer; a test supplies captured HTML instead of a live site.
protocol ExtensionBrowserExtracting: AnyObject {
    func extract(_ request: HostBrowserRequest) async throws -> HostBrowserResult
}

/// Adapts S5's `HostBrowserCapability`, which is `@MainActor` because it drives a
/// `WKWebView`.
final class MainActorBrowserExtractor: ExtensionBrowserExtracting {
    private let capability: HostBrowserCapability

    init(capability: HostBrowserCapability) {
        self.capability = capability
    }

    func extract(_ request: HostBrowserRequest) async throws -> HostBrowserResult {
        try await capability.extract(request)
    }
}

/// Installs `context.host.browser`.
final class HostBrowserJSCapability: ExtensionHostCapability {

    let hostName = "browser"

    private let extractor: any ExtensionBrowserExtracting

    init(extractor: any ExtensionBrowserExtracting) {
        self.extractor = extractor
    }

    func makeHostValue(in context: JSContext, scope: ExtensionInvocationScope) -> JSValue? {
        guard let object = JSValue(newObjectIn: context) else { return nil }
        let extract: @convention(block) (JSValue?) -> JSValue? = { [weak self] request in
            guard let self, let request else { return nil }
            return self.promise(for: request, in: context, scope: scope)
        }
        object.setObject(extract, forKeyedSubscript: "extract" as NSString)
        return object
    }

    // MARK: - One extraction

    private func promise(for requestValue: JSValue,
                         in context: JSContext,
                         scope: ExtensionInvocationScope) -> JSValue? {
        guard let promiseType = context.objectForKeyedSubscript("Promise") else { return nil }

        var resolve: JSValue?
        var reject: JSValue?
        let executor: @convention(block) (JSValue?, JSValue?) -> Void = { onResolve, onReject in
            resolve = onResolve
            reject = onReject
        }
        guard let promise = promiseType.construct(withArguments: [executor]),
              let resolve, let reject else {
            return nil
        }

        let request: HostBrowserRequest
        do {
            request = try Self.decodeRequest(requestValue, bridge: scope.bridge)
        } catch let error as HostCapabilityError {
            Self.settle(reject, with: error, in: context)
            return promise
        } catch {
            Self.settle(reject,
                        with: HostCapabilityError(code: .invalidRequest,
                                                  message: "\(error)"),
                        in: context)
            return promise
        }

        // Admission before work: a cancelled invocation starts no browser navigation.
        let work = CancellableWork()
        guard let call = scope.admitHostCall(onCancel: { work.cancel() }) else {
            Self.settle(reject,
                        with: HostCapabilityError(code: .cancelled,
                                                  message: "the invocation was cancelled"),
                        in: context)
            return promise
        }

        work.task = Task { [extractor] in
            do {
                let result = try await extractor.extract(request)
                call.deliver { context in
                    guard let converted = Self.resultValue(result, in: context) else {
                        Self.settle(reject,
                                    with: HostCapabilityError(
                                        code: .invalidResponse,
                                        message: "the extraction result is not a JSON value"),
                                    in: context)
                        return
                    }
                    resolve.call(withArguments: [converted])
                }
            } catch let error as HostCapabilityError {
                call.deliver { context in Self.settle(reject, with: error, in: context) }
            } catch is CancellationError {
                call.deliver { context in
                    Self.settle(reject,
                                with: HostCapabilityError(code: .cancelled,
                                                          message: "the invocation was cancelled"),
                                in: context)
                }
            } catch {
                call.deliver { context in
                    Self.settle(reject,
                                with: HostCapabilityError(code: .navigation,
                                                          message: "\(error)"),
                                in: context)
                }
            }
        }
        return promise
    }

    // MARK: - Conversion

    private static func decodeRequest(_ value: JSValue,
                                      bridge: ExtensionJSBridge) throws -> HostBrowserRequest {
        let converted: Any
        do {
            converted = try bridge.jsonValue(from: value, path: "browser.extract")
        } catch {
            throw HostCapabilityError(code: .invalidRequest,
                                      message: "the extract request is not a JSON value")
        }
        guard let object = converted as? [String: Any] else {
            throw HostCapabilityError(code: .invalidRequest,
                                      message: "extract expects an object")
        }
        guard let rawURL = object["url"] as? String, let url = URL(string: rawURL) else {
            throw HostCapabilityError(code: .invalidRequest,
                                      message: "extract requires a url string")
        }
        guard let script = object["script"] as? String, !script.isEmpty else {
            throw HostCapabilityError(code: .invalidRequest,
                                      message: "extract requires a script string")
        }
        let interaction: HostBrowserInteraction
        if let raw = object["interaction"] as? String {
            guard let parsed = HostBrowserInteraction(rawValue: raw) else {
                throw HostCapabilityError(code: .invalidRequest,
                                          message: "interaction must be allowForeground or never")
            }
            interaction = parsed
        } else {
            interaction = .allowForeground
        }
        return HostBrowserRequest(url: url, script: script, interaction: interaction)
    }

    private static func resultValue(_ result: HostBrowserResult, in context: JSContext) -> JSValue? {
        guard let value = try? result.value.foundationValue else { return nil }
        let warnings = result.warnings.compactMap { warning -> [String: Any]? in
            var encoded: [String: Any] = ["code": warning.code.rawValue,
                                          "fieldPath": warning.fieldPath]
            if let index = warning.itemIndex { encoded["itemIndex"] = index }
            return encoded
        }
        return JSValue(object: ["value": value,
                                "finalURL": result.finalURL.absoluteString,
                                "warnings": warnings],
                       in: context)
    }

    /// Rejects with a real `Error` carrying `hostErrorCode`, which is the same channel
    /// the runtime's own cancellation error uses.
    private static func settle(_ reject: JSValue,
                               with error: HostCapabilityError,
                               in context: JSContext) {
        guard let errorType = context.objectForKeyedSubscript("Error"),
              let value = errorType.construct(withArguments: [error.message]) else {
            return
        }
        value.setObject(error.code.rawValue, forKeyedSubscript: "hostErrorCode" as NSString)
        if let seconds = error.retryAfterSeconds {
            value.setObject(seconds, forKeyedSubscript: "retryAfterSeconds" as NSString)
        }
        reject.call(withArguments: [value])
    }
}

/// A box so `onCancel` can reach a `Task` created after admission.
private final class CancellableWork {
    private let lock = NSLock()
    private var stored: Task<Void, Never>?
    private var cancelled = false

    var task: Task<Void, Never>? {
        get { lock.withLock { stored } }
        set {
            let shouldCancel: Bool = lock.withLock {
                stored = newValue
                return cancelled
            }
            if shouldCancel { newValue?.cancel() }
        }
    }

    func cancel() {
        let pending: Task<Void, Never>? = lock.withLock {
            cancelled = true
            return stored
        }
        pending?.cancel()
    }
}
