//
//  HostJSCapabilitySupport.swift
//  MangaCarta
//
//  Shared asynchronous JavaScriptCore plumbing for Host API capabilities. Each
//  adapter still owns its request and response wire shapes; this type owns the
//  invariant seam: admission, cancellation, Promise settlement, and Host API
//  error-code preservation.
//

import Foundation
import JavaScriptCore

struct HostJSPromisePlan<Request, Result> {
    let decode: (JSValue, ExtensionJSBridge) throws -> Request
    let perform: (Request) async throws -> Result
    let encode: (Result, JSContext) -> JSValue?
    let fallbackErrorCode: ExtensionHostErrorCode

    init(decode: @escaping (JSValue, ExtensionJSBridge) throws -> Request,
         perform: @escaping (Request) async throws -> Result,
         encode: @escaping (Result, JSContext) -> JSValue?,
         fallbackErrorCode: ExtensionHostErrorCode) {
        self.decode = decode
        self.perform = perform
        self.encode = encode
        self.fallbackErrorCode = fallbackErrorCode
    }
}

enum HostJSCapabilitySupport {

    static func promise<Request, Result>(
        for requestValue: JSValue?,
        in context: JSContext,
        scope: ExtensionInvocationScope,
        plan: HostJSPromisePlan<Request, Result>
    ) -> JSValue? {
        guard let promiseType = context.objectForKeyedSubscript("Promise") else { return nil }

        var resolve: JSValue?
        var reject: JSValue?
        let executor: @convention(block) (JSValue?, JSValue?) -> Void = { onResolve, onReject in
            resolve = onResolve
            reject = onReject
        }
        guard let promise = promiseType.construct(withArguments: [executor]),
              let resolve,
              let reject else { return nil }

        guard let requestValue else {
            settle(reject,
                   with: HostCapabilityError(code: .invalidRequest,
                                             message: "the host call requires an argument"),
                   in: context)
            return promise
        }

        let request: Request
        do {
            request = try plan.decode(requestValue, scope.bridge)
        } catch let error as HostCapabilityError {
            settle(reject, with: error, in: context)
            return promise
        } catch {
            settle(reject,
                   with: HostCapabilityError(code: .invalidRequest,
                                             message: "the host call request is invalid"),
                   in: context)
            return promise
        }

        let work = CancellableWork()
        guard let call = scope.admitHostCall(onCancel: { work.cancel() }) else {
            settle(reject,
                   with: HostCapabilityError(code: .cancelled,
                                             message: "the invocation was cancelled"),
                   in: context)
            return promise
        }

        work.task = Task {
            do {
                let result = try await plan.perform(request)
                call.deliver { context in
                    guard let converted = plan.encode(result, context) else {
                        settle(reject,
                               with: HostCapabilityError(
                                   code: .invalidResponse,
                                   message: "the host result is not a JSON value"),
                               in: context)
                        return
                    }
                    resolve.call(withArguments: [converted])
                }
            } catch let error as HostCapabilityError {
                call.deliver { context in settle(reject, with: error, in: context) }
            } catch is CancellationError {
                call.deliver { context in
                    settle(reject,
                           with: HostCapabilityError(code: .cancelled,
                                                     message: "the invocation was cancelled"),
                           in: context)
                }
            } catch {
                call.deliver { context in
                           settle(reject,
                           with: HostCapabilityError(code: plan.fallbackErrorCode,
                                                     message: "the host capability failed"),
                           in: context)
                }
            }
        }
        return promise
    }

    static func settle(_ reject: JSValue,
                       with error: HostCapabilityError,
                       in context: JSContext) {
        guard let errorType = context.objectForKeyedSubscript("Error"),
              let value = errorType.construct(withArguments: [error.message]) else { return }
        value.setObject(error.code.rawValue, forKeyedSubscript: "hostErrorCode" as NSString)
        if let seconds = error.retryAfterSeconds {
            value.setObject(seconds, forKeyedSubscript: "retryAfterSeconds" as NSString)
        }
        reject.call(withArguments: [value])
    }
}

/// A box so cancellation can reach a Task created after admission.
final class CancellableWork {
    private let lock = NSLock()
    private var stored: Task<Void, Never>?
    private var cancelled = false

    var task: Task<Void, Never>? {
        get { lock.withLock { stored } }
        set {
            let shouldCancel = lock.withLock {
                stored = newValue
                return cancelled
            }
            if shouldCancel { newValue?.cancel() }
        }
    }

    func cancel() {
        let pending = lock.withLock { () -> Task<Void, Never>? in
            cancelled = true
            return stored
        }
        pending?.cancel()
    }
}
