//
//  HostLogJSCapability.swift
//  MangaCarta
//
//  Installs bounded `context.host.log(level, event, fields)` over HostLogger.
//

import Foundation
import JavaScriptCore

final class HostLogJSCapability: ExtensionHostCapability {

    let hostName = "log"
    private let logger: HostLogger

    init(logger: HostLogger) {
        self.logger = logger
    }

    func makeHostValue(in context: JSContext, scope: ExtensionInvocationScope) -> JSValue? {
        let log: @convention(block) (JSValue?, JSValue?, JSValue?) -> JSValue? = { [logger] level, event, fields in
            guard let request = Self.logRequest(level: level, event: event, fields: fields,
                                                in: context) else {
                return HostJSCapabilitySupport.promise(
                    for: nil,
                    in: context,
                    scope: scope,
                    plan: HostJSPromisePlan(
                        decode: Self.decodeLog,
                        perform: { _ in .null },
                        encode: Self.jsonValue,
                        fallbackErrorCode: .invalidRequest))
            }
            return HostJSCapabilitySupport.promise(
                for: request,
                in: context,
                scope: scope,
                plan: HostJSPromisePlan(
                    decode: Self.decodeLog,
                    perform: { level, event, fields in
                        try await logger.log(level: level, event: event, fields: fields)
                        return .null
                    },
                    encode: Self.jsonValue,
                    fallbackErrorCode: .invalidRequest))
        }
        return JSValue(object: log, in: context)
    }

    private static func logRequest(level: JSValue?,
                                   event: JSValue?,
                                   fields: JSValue?,
                                   in context: JSContext) -> JSValue? {
        guard let level, let event,
              let request = JSValue(newObjectIn: context) else { return nil }
        request.setValue(level, forProperty: "level")
        request.setValue(event, forProperty: "event")
        if let fields, !fields.isUndefined {
            request.setValue(fields, forProperty: "fields")
        } else {
            request.setObject(JSValue(newObjectIn: context),
                              forKeyedSubscript: "fields" as NSString)
        }
        return request
    }

    private static func decodeLog(_ value: JSValue,
                                  bridge: ExtensionJSBridge) throws
        -> (HostLogLevel, String, [String: JSONValue]) {
        let raw: Any
        do {
            raw = try bridge.jsonValue(from: value, path: "log")
        } catch {
            throw HostCapabilityError(code: .invalidRequest,
                                      message: "log arguments are not JSON values")
        }
        guard let object = raw as? [String: Any],
              let rawLevel = object["level"] as? String,
              let level = HostLogLevel(rawValue: rawLevel),
              let event = object["event"] as? String,
              let rawFields = object["fields"] as? [String: Any] else {
            throw HostCapabilityError(code: .invalidRequest,
                                      message: "log requires a level, event, and fields object")
        }
        var fields: [String: JSONValue] = [:]
        for (name, rawValue) in rawFields {
            guard let jsonValue = try? HostJSONValueConverter.convert(rawValue) else {
                throw HostCapabilityError(code: .invalidRequest,
                                          message: "log fields must be JSON scalars")
            }
            fields[name] = jsonValue
        }
        return (level, event, fields)
    }

    private static func jsonValue(_ value: JSONValue,
                                  in context: JSContext) -> JSValue? {
        guard let foundation = try? value.foundationValue else { return nil }
        return JSValue(object: foundation, in: context)
    }
}
