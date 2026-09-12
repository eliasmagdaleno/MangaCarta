//
//  HostHTTPJSCapability.swift
//  MangaCarta
//
//  Installs `context.host.http` over the typed HostHTTPClient.
//

import Foundation
import JavaScriptCore

final class HostHTTPJSCapability: ExtensionHostCapability {

    let hostName = "http"
    private let client: HostHTTPClient

    init(client: HostHTTPClient) {
        self.client = client
    }

    func makeHostValue(in context: JSContext, scope: ExtensionInvocationScope) -> JSValue? {
        guard let object = JSValue(newObjectIn: context) else { return nil }
        let request: @convention(block) (JSValue?) -> JSValue? = { [client] value in
            HostJSCapabilitySupport.promise(
                for: value,
                in: context,
                scope: scope,
                plan: HostJSPromisePlan(
                    decode: Self.decodeRequest,
                    perform: { request in try await client.request(request) },
                    encode: Self.responseValue,
                    fallbackErrorCode: .network))
        }
        object.setObject(request, forKeyedSubscript: "request" as NSString)
        return object
    }

    private static func decodeRequest(
        _ value: JSValue,
        bridge: ExtensionJSBridge
    ) throws -> HostHTTPRequest {
        let raw: Any
        do {
            raw = try bridge.jsonValue(from: value, path: "http.request")
        } catch {
            throw HostCapabilityError(code: .invalidRequest,
                                      message: "the HTTP request is not a JSON value")
        }
        guard let object = raw as? [String: Any] else {
            throw HostCapabilityError(code: .invalidRequest,
                                      message: "http.request expects an object")
        }
        guard let rawURL = object["url"] as? String,
              let url = URL(string: rawURL) else {
            throw HostCapabilityError(code: .invalidRequest,
                                      message: "http.request requires a url string")
        }

        let method = try decodeMethod(object["method"])
        let headers = try decodeHeaders(object["headers"])
        let body = try decodeBody(object["body"])
        let timeoutClass = try decodeTimeoutClass(object["timeoutClass"])
        let responseType = try decodeResponseType(object["responseType"])

        return HostHTTPRequest(url: url,
                               method: method,
                               headers: headers,
                               body: body,
                               timeoutClass: timeoutClass,
                               responseType: responseType)
    }

    private static func decodeMethod(_ raw: Any?) throws -> HostHTTPMethod {
        guard let rawMethod = raw as? String else { return .get }
        guard let method = HostHTTPMethod(rawValue: rawMethod.uppercased()) else {
            throw HostCapabilityError(code: .invalidRequest,
                                      message: "http.request method is unsupported")
        }
        return method
    }

    private static func decodeHeaders(_ raw: Any?) throws -> [String: String] {
        guard let raw else { return [:] }
        guard let values = raw as? [String: Any] else {
            throw HostCapabilityError(code: .invalidRequest,
                                      message: "http.request headers must be an object")
        }
        var headers: [String: String] = [:]
        for (name, value) in values {
            guard let string = value as? String else {
                throw HostCapabilityError(code: .invalidRequest,
                                          message: "http.request header values must be strings")
            }
            headers[name] = string
        }
        return headers
    }

    private static func decodeTimeoutClass(_ raw: Any?) throws -> HostHTTPTimeoutClass {
        guard let rawTimeout = raw as? String else { return .interactive }
        switch rawTimeout {
        case "interactive": return .interactive
        case "background": return .background
        default:
            throw HostCapabilityError(code: .invalidRequest,
                                      message: "http.request timeoutClass is unsupported")
        }
    }

    private static func decodeResponseType(_ raw: Any?) throws -> HostHTTPResponseType {
        guard let rawResponse = raw as? String else { return .text }
        switch rawResponse {
        case "text": return .text
        case "base64": return .base64
        default:
            throw HostCapabilityError(code: .invalidRequest,
                                      message: "http.request responseType is unsupported")
        }
    }

    private static func decodeBody(_ raw: Any?) throws -> HostHTTPBody? {
        guard let raw, !(raw is NSNull) else { return nil }
        if let text = raw as? String { return .text(text) }
        guard let object = raw as? [String: Any] else {
            throw HostCapabilityError(code: .invalidRequest,
                                      message: "http.request body must be text or base64")
        }
        if let type = object["type"] as? String,
           let value = object["value"] as? String {
            switch type {
            case "text": return .text(value)
            case "base64": return .base64(value)
            default: break
            }
        }
        if let text = object["text"] as? String { return .text(text) }
        if let base64 = object["base64"] as? String { return .base64(base64) }
        throw HostCapabilityError(code: .invalidRequest,
                                  message: "http.request body must be text or base64")
    }

    private static func responseValue(_ response: HostHTTPResponse,
                                      in context: JSContext) -> JSValue? {
        let body: String
        switch response.body {
        case .text(let value): body = value
        case .base64(let value): body = value
        }
        var object: [String: Any] = [
            "status": response.status,
            "finalURL": response.finalURL.absoluteString,
            "headers": response.headers,
            "body": body
        ]
        if let retryAfter = response.retryAfterSeconds {
            object["retryAfterSeconds"] = retryAfter
        }
        return JSValue(object: object, in: context)
    }
}
