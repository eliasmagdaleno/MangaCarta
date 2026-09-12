//
//  ExtensionRuntimeTests.swift
//  MangaCartaTests
//
//  The invocation bridge: the message contract from the Host API design's
//  "Configuration-first Sources" and "Envelope and value rules" sections, and the
//  scheduling and cancellation rules from "Scheduling, budgets, and cancellation".
//
//  Cancellation is acceptance criterion 7 — "cancellation prevents every late
//  callback from changing invocation state". The tests that carry it are in
//  `ExtensionCancellationTests`; this file covers the contract around it.
//

import Foundation
import JavaScriptCore
import XCTest
@testable import MangaCarta

final class ExtensionRuntimeTests: XCTestCase {

    // MARK: - The message contract

    func testEngineReceivesTheOperationRequestAndItsOwnSourceContext() async throws {
        let runtime = makeRuntime(script: """
            registerEngine("madara", { invoke: function (operation, request, context) {
              return { ok: true, value: {
                operation: operation,
                query: request.query,
                page: request.page,
                id: context.source.id,
                baseURL: context.source.configuration.baseURL,
                mode: context.source.languages.mode,
                languages: context.source.languages.values,
                aborted: context.signal.aborted
              } };
            } });
        """)

        let value = try await runtime.invoke(.search, request: ["query": "abc", "page": 1])
        let object = try XCTUnwrap(value as? [String: Any])
        XCTAssertEqual(object["operation"] as? String, "search")
        XCTAssertEqual(object["query"] as? String, "abc")
        XCTAssertEqual(object["page"] as? Int, 1)
        XCTAssertEqual(object["id"] as? String, "repo-a:example")
        XCTAssertEqual(object["baseURL"] as? String, "https://example.test")
        XCTAssertEqual(object["mode"] as? String, "fixed")
        XCTAssertEqual(object["languages"] as? [String], ["en"])
        XCTAssertEqual(object["aborted"] as? Bool, false)
    }

    func testAwaitsAPromiseResult() async throws {
        let runtime = makeRuntime(script: """
            registerEngine("madara", { invoke: function () {
              return Promise.resolve(1).then(function () {
                return { ok: true, value: { settled: true } };
              });
            } });
        """)
        let value = try await runtime.invoke(.search, request: [:])
        let object = try XCTUnwrap(value as? [String: Any])
        XCTAssertEqual(object["settled"] as? Bool, true)
    }

    /// "Configuration is deep-frozen before invocation."
    func testConfigurationAndRequestAreDeepFrozen() async throws {
        let runtime = makeRuntime(script: """
            registerEngine("madara", { invoke: function (operation, request, context) {
              try { context.source.configuration.selectors.title = "x"; } catch (e) {}
              try { request.query = "x"; } catch (e) {}
              return { ok: true, value: {
                title: context.source.configuration.selectors.title,
                query: request.query
              } };
            } });
        """)
        let raw = try await runtime.invoke(.search, request: ["query": "abc"])
        let object = try XCTUnwrap(raw as? [String: Any])
        XCTAssertEqual(object["title"] as? String, ".t")
        XCTAssertEqual(object["query"] as? String, "abc")
    }

    /// A context per invocation, so nothing an engine leaves on `globalThis` survives
    /// into the next call — and nothing it writes can be read by another Source.
    func testEachInvocationGetsAFreshContext() async throws {
        let runtime = makeRuntime(script: """
            registerEngine("madara", { invoke: function () {
              var seen = typeof globalThis.leaked;
              globalThis.leaked = "from a previous invocation";
              return { ok: true, value: { seen: seen } };
            } });
        """)
        let firstValue = try await runtime.invoke(.search, request: [:])
        let secondValue = try await runtime.invoke(.search, request: [:])
        let first = try XCTUnwrap(firstValue as? [String: Any])
        let second = try XCTUnwrap(secondValue as? [String: Any])
        XCTAssertEqual(first["seen"] as? String, "undefined")
        XCTAssertEqual(second["seen"] as? String, "undefined")
    }

    /// "An engine cannot enumerate other installed Source configurations or invoke
    /// another Source." The only Source-shaped thing reachable is its own.
    func testEngineSeesNoOtherSourceAndNoRegistry() async throws {
        let runtime = makeRuntime(script: """
            registerEngine("madara", { invoke: function (operation, request, context) {
              return { ok: true, value: {
                keys: Object.keys(context).sort().join(","),
                sourceKeys: Object.keys(context.source).sort().join(","),
                registry: typeof globalThis.sources + "/" + typeof globalThis.registry
                          + "/" + typeof globalThis.SourceRegistry
              } };
            } });
        """)
        let raw = try await runtime.invoke(.search, request: [:])
        let object = try XCTUnwrap(raw as? [String: Any])
        XCTAssertEqual(object["keys"] as? String, "host,signal,source")
        XCTAssertEqual(object["sourceKeys"] as? String, "configuration,id,languages")
        XCTAssertEqual(object["registry"] as? String, "undefined/undefined/undefined")
    }

    /// "Extensions cannot create timers or detached work that outlive the invocation."
    func testNoTimersOrAmbientNetworkingAreReachable() async throws {
        let runtime = makeRuntime(script: """
            registerEngine("madara", { invoke: function () {
              return { ok: true, value: { probes: [
                typeof setTimeout, typeof setInterval, typeof queueMicrotask,
                typeof requestAnimationFrame, typeof XMLHttpRequest, typeof fetch,
                typeof Worker, typeof importScripts
              ].join(",") } };
            } });
        """)
        let raw = try await runtime.invoke(.search, request: [:])
        let object = try XCTUnwrap(raw as? [String: Any])
        XCTAssertEqual(object["probes"] as? String,
                       "undefined,undefined,undefined,undefined,undefined,undefined,undefined,undefined")
    }

    func testHostObjectContainsOnlyInstalledCapabilities() async throws {
        let capability = ProbeHostCapability()
        let runtime = makeRuntime(script: """
            registerEngine("madara", { invoke: function (operation, request, context) {
              return { ok: true, value: { hostKeys: Object.keys(context.host).sort().join(",") } };
            } });
        """, capabilities: [capability])
        let raw = try await runtime.invoke(.search, request: [:])
        let object = try XCTUnwrap(raw as? [String: Any])
        XCTAssertEqual(object["hostKeys"] as? String, "probe")
    }

    // MARK: - The envelope

    func testErrorEnvelopeBecomesATypedHostError() async throws {
        let runtime = makeRuntime(script: """
            registerEngine("madara", { invoke: function () {
              return { ok: false, error: { code: "rate_limited", message: "slow down",
                                           retryAfterSeconds: 30, details: { origin: "a" } } };
            } });
        """)
        let error = await invocationError(runtime, .search)
        XCTAssertEqual(error?.code, .rateLimited)
        XCTAssertEqual(error?.message, "slow down")
        XCTAssertEqual(error?.retryAfterSeconds, 30)
        XCTAssertEqual(error?.details, .object(["origin": .string("a")]))
    }

    func testUnknownErrorCodeIsInvalidResponse() async throws {
        let runtime = makeRuntime(script: """
            registerEngine("madara", { invoke: function () {
              return { ok: false, error: { code: "totally_made_up" } };
            } });
        """)
        let error = await invocationError(runtime, .search)
        XCTAssertEqual(error?.code, .invalidResponse)
    }

    func testMalformedEnvelopesAreInvalidResponse() async throws {
        for script in ["return { value: 1 };",
                       "return { ok: true };",
                       "return { ok: \"yes\", value: 1 };",
                       "return { ok: false };",
                       "return [1, 2];",
                       "return \"ok\";"] {
            let runtime = makeRuntime(script: """
                registerEngine("madara", { invoke: function () { \(script) } });
            """)
            let error = await invocationError(runtime, .search)
            XCTAssertEqual(error?.code, .invalidResponse, "script: \(script)")
        }
    }

    /// The envelope's `value` crosses the same pre-conversion boundary as everything
    /// else: a function hidden inside a result is not a schema problem, it is not JSON.
    func testResultValueCrossesThePreConversionBoundary() async throws {
        let runtime = makeRuntime(script: """
            registerEngine("madara", { invoke: function () {
              return { ok: true, value: { items: [{ id: "a", title: "T", parse: function () {} }] } };
            } });
        """)
        let error = await invocationError(runtime, .search)
        XCTAssertEqual(error?.code, .invalidResponse)
    }

    func testThrownEngineErrorIsScript() async throws {
        let runtime = makeRuntime(script: """
            registerEngine("madara", { invoke: function () { throw new Error("boom"); } });
        """)
        let error = await invocationError(runtime, .search)
        XCTAssertEqual(error?.code, .script)
        XCTAssertEqual(error?.message?.contains("boom"), true)
    }

    func testRejectedPromiseIsScript() async throws {
        let runtime = makeRuntime(script: """
            registerEngine("madara", { invoke: function () {
              return Promise.reject(new Error("nope"));
            } });
        """)
        let error = await invocationError(runtime, .search)
        XCTAssertEqual(error?.code, .script)
    }

    func testBundleThatFailsToEvaluateIsScript() async throws {
        let runtime = makeRuntime(script: "this is not javascript {{{")
        let error = await invocationError(runtime, .search)
        XCTAssertEqual(error?.code, .script)
    }

    func testMissingEngineIsUnsupported() async throws {
        let runtime = makeRuntime(script: """
            registerEngine("some-other-engine", { invoke: function () {
              return { ok: true, value: {} };
            } });
        """)
        let error = await invocationError(runtime, .search)
        XCTAssertEqual(error?.code, .unsupported)
    }

    func testEngineWithoutACallableInvokeIsUnsupported() async throws {
        let runtime = makeRuntime(script: "registerEngine(\"madara\", { invoke: 42 });")
        let error = await invocationError(runtime, .search)
        XCTAssertEqual(error?.code, .unsupported)
    }

    /// "The runtime calls only declared capabilities." Asking for an undeclared one is
    /// a host bug, and it must be caught before any Extension code runs.
    func testUndeclaredCapabilityIsInvalidRequestAndEvaluatesNoScript() async throws {
        let runtime = makeRuntime(script: """
            globalThis.__evaluated = true;
            registerEngine("madara", { invoke: function () { return { ok: true, value: {} }; } });
        """)
        let error = await invocationError(runtime, .tagBrowse)
        XCTAssertEqual(error?.code, .invalidRequest)
        XCTAssertFalse(runtime.didEvaluateBundle)
    }

    func testEveryErrorCarriesTheInvocationIdentity() async throws {
        let runtime = makeRuntime(script: """
            registerEngine("madara", { invoke: function () { throw new Error("boom"); } });
        """)
        let first = await invocationError(runtime, .search)
        let second = await invocationError(runtime, .search)
        XCTAssertNotNil(first?.invocationID)
        XCTAssertNotEqual(first?.invocationID, second?.invocationID)
    }

    // MARK: - Helpers

    private func invocationError(_ runtime: ExtensionRuntime,
                                 _ operation: SourceOperation) async -> ExtensionInvocationError? {
        do {
            let value = try await runtime.invoke(operation, request: [:])
            XCTFail("expected a failure, got \(value)")
            return nil
        } catch let error as ExtensionInvocationError {
            return error
        } catch {
            XCTFail("unexpected error \(error)")
            return nil
        }
    }

    private func makeRuntime(script: String,
                             capabilities: [ExtensionHostCapability] = [],
                             gracePeriod: TimeInterval = 0.2) -> ExtensionRuntime {
        ExtensionRuntime(bundleScript: script,
                         declaration: ExtensionRuntimeFixtures.declaration(),
                         capabilities: capabilities,
                         cancellationGracePeriod: gracePeriod)
    }
}

// MARK: - Fixtures

enum ExtensionRuntimeFixtures {

    /// A validated declaration, obtained the only way one can be: from JSON through
    /// `SourceDeclarationValidator`. This used to hand-build the struct; ADR-0003
    /// Amendment 4 (decision 4, #161) made the initialiser private to the validator, so
    /// the fixture is now the same path a real install takes.
    static func declaration(
        qualifiedID: String = "repo-a:example",
        engine: String = "madara",
        configuration: JSONValue = .object([
            "baseURL": .string("https://example.test"),
            "selectors": .object(["title": .string(".t")])
        ])
    ) -> SourceDeclaration {
        let json: JSONValue = .object([
            "localId": .string("example"),
            "name": .string("Example Manga"),
            "engine": .string(engine),
            "configuration": configuration,
            "adult": .string("none"),
            "capabilities": .object(["search": .bool(true), "detail": .bool(true),
                                     "chapters": .bool(true), "pages": .bool(true),
                                     "popular": .bool(true)]),
            "languages": .object(["mode": .string("fixed"),
                                  "values": .array([.string("en")])]),
            "network": .object(["httpOrigins": .array([.string("https://example.test")]),
                                "browserOrigins": .array([.string("https://example.test")]),
                                "assetOrigins": .array([.string("https://cdn.example.test")])]),
            "hostAPI": .object(["minimum": .string("1.0"), "maximumExclusive": .string("2.0")])
        ])
        switch SourceDeclarationValidator.validate(json: json,
                                                   qualifiedId: QualifiedSourceID(rawValue: qualifiedID),
                                                   hostAPI: .v1) {
        case .success(let declaration):
            return declaration
        case .failure(let error):
            preconditionFailure("fixture declaration failed to validate: \(error)")
        }
    }
}

/// A `context.host` member that does nothing but exist, so the shape of the host
/// object can be asserted without depending on S5's capabilities.
final class ProbeHostCapability: ExtensionHostCapability {
    let hostName = "probe"

    func makeHostValue(in context: JSContext, scope: ExtensionInvocationScope) -> JSValue? {
        JSValue(newObjectIn: context)
    }
}
