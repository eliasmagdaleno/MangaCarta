//
//  HostStorageJSCapability.swift
//  MangaCarta
//
//  Installs `context.host.storage` over the typed HostStorage.
//

import Foundation
import JavaScriptCore

final class HostStorageJSCapability: ExtensionHostCapability {

    let hostName = "storage"
    private let storage: HostStorage

    init(storage: HostStorage) {
        self.storage = storage
    }

    func makeHostValue(in context: JSContext, scope: ExtensionInvocationScope) -> JSValue? {
        guard let object = JSValue(newObjectIn: context) else { return nil }

        let get: @convention(block) (JSValue?) -> JSValue? = { [storage] value in
            HostJSCapabilitySupport.promise(
                for: value,
                in: context,
                scope: scope,
                plan: HostJSPromisePlan(
                    decode: Self.decodeKey,
                    perform: { key in try await storage.get(key) ?? .null },
                    encode: Self.jsonValue,
                    fallbackErrorCode: .storage))
        }
        let set: @convention(block) (JSValue?, JSValue?) -> JSValue? = { [storage] key, value in
            guard let request = Self.setRequest(key: key, value: value, in: context) else {
                return HostJSCapabilitySupport.promise(
                    for: nil,
                    in: context,
                    scope: scope,
                    plan: HostJSPromisePlan(
                        decode: Self.decodeKey,
                        perform: { _ in .null },
                        encode: Self.jsonValue,
                        fallbackErrorCode: .storage))
            }
            return HostJSCapabilitySupport.promise(
                for: request,
                in: context,
                scope: scope,
                plan: HostJSPromisePlan(
                    decode: Self.decodeSet,
                    perform: { key, value in
                        try await storage.set(key, value: value)
                        return .null
                    },
                    encode: Self.jsonValue,
                    fallbackErrorCode: .storage))
        }
        let remove: @convention(block) (JSValue?) -> JSValue? = { [storage] value in
            HostJSCapabilitySupport.promise(
                for: value,
                in: context,
                scope: scope,
                plan: HostJSPromisePlan(
                    decode: Self.decodeKey,
                    perform: { key in
                        try await storage.remove(key)
                        return .null
                    },
                    encode: Self.jsonValue,
                    fallbackErrorCode: .storage))
        }
        let keys: @convention(block) (JSValue?) -> JSValue? = { [storage] value in
            HostJSCapabilitySupport.promise(
                for: value,
                in: context,
                scope: scope,
                plan: HostJSPromisePlan(
                    decode: Self.decodeKey,
                    perform: { prefix in try await storage.keys(prefix: prefix) },
                    encode: { values, context in JSValue(object: values, in: context) },
                    fallbackErrorCode: .storage))
        }
        object.setObject(get, forKeyedSubscript: "get" as NSString)
        object.setObject(set, forKeyedSubscript: "set" as NSString)
        object.setObject(remove, forKeyedSubscript: "remove" as NSString)
        object.setObject(keys, forKeyedSubscript: "keys" as NSString)
        return object
    }

    private static func decodeKey(_ value: JSValue,
                                  bridge: ExtensionJSBridge) throws -> String {
        guard let raw = try? bridge.jsonValue(from: value, path: "storage.key"),
              let key = raw as? String else {
            throw HostCapabilityError(code: .invalidRequest,
                                      message: "storage keys must be strings")
        }
        return key
    }

    private static func setRequest(key: JSValue?,
                                   value: JSValue?,
                                   in context: JSContext) -> JSValue? {
        guard let key, let value, !value.isUndefined,
              let request = JSValue(newObjectIn: context) else { return nil }
        request.setValue(key, forProperty: "key")
        request.setValue(value, forProperty: "value")
        return request
    }

    private static func decodeSet(_ value: JSValue,
                                  bridge: ExtensionJSBridge) throws -> (String, JSONValue) {
        let raw: Any
        do {
            raw = try bridge.jsonValue(from: value, path: "storage.set")
        } catch {
            throw HostCapabilityError(code: .invalidRequest,
                                      message: "storage.set expects JSON values")
        }
        guard let object = raw as? [String: Any],
              let key = object["key"] as? String,
              let rawValue = object["value"],
              let jsonValue = try? HostJSONValueConverter.convert(rawValue) else {
            throw HostCapabilityError(code: .invalidRequest,
                                      message: "storage.set expects a key and JSON value")
        }
        return (key, jsonValue)
    }

    private static func jsonValue(_ value: JSONValue,
                                  in context: JSContext) -> JSValue? {
        guard let foundation = try? value.foundationValue else { return nil }
        return JSValue(object: foundation, in: context)
    }
}
