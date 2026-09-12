//
//  ManifestValidationCodeFreeTests.swift
//  MangaCartaTests
//
//  Acceptance criterion 2 of the Host API design: "manifest validation and Source
//  registration execute no Extension code."
//
//  The evidence here is deliberately STRUCTURAL rather than behavioural. Observing that
//  no callback fired during one validation would only prove that one path stayed quiet;
//  it would not prove the validator lacks the capability. So this suite reads the
//  manifest-validation sources off disk (resolved from `#filePath`, the same trick the
//  golden tests use) and asserts that the whole subsystem never names an evaluator.
//
//  What this cannot prove: the app process links WebKit for `WebViewService`, and WebKit
//  loads JavaScriptCore transitively, so a process-level "is JavaScriptCore loaded" check
//  would be meaningless here. File scope is the honest boundary — the claim is that no
//  file in the validation subsystem can reach an evaluator, and this test goes red the
//  moment one of them tries.
//

import XCTest
@testable import MangaCarta

final class ManifestValidationCodeFreeTests: XCTestCase {

    /// Every file that participates in validating a Source declaration. Adding a file to
    /// the subsystem without adding it here is caught by `testEverySubsystemFileExists`
    /// only for renames; the list is the definition of the boundary and is meant to be
    /// edited deliberately.
    private static let subsystemFiles = [
        "MangaCarta/Models/JSONValue.swift",
        "MangaCarta/Models/HostAPIVersion.swift",
        "MangaCarta/Models/SourceDeclaration.swift",
        "MangaCarta/Models/SourceDeclarationValidator.swift"
    ]

    /// Tokens that would mean the subsystem can reach a JavaScript evaluator, a browser,
    /// or a dynamic-dispatch escape hatch that could reach one indirectly.
    private static let forbiddenTokens = [
        "JavaScriptCore", "JSContext", "JSValue", "JSVirtualMachine", "JSManagedValue",
        "JSExport", "evaluateScript", "WebKit", "WKWebView", "WKUserScript",
        "NSExpression", "NSClassFromString", "dlopen", "dlsym", "Process("
    ]

    private var repositoryRoot: URL {
        URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent()   // MangaCartaTests
            .deletingLastPathComponent()   // repository root
    }

    private func source(of relativePath: String) throws -> String {
        let url = repositoryRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Guards the guard: if a file is renamed away, the token scan below would otherwise
    /// pass vacuously.
    func testEverySubsystemFileExists() throws {
        for path in Self.subsystemFiles {
            let text = try source(of: path)
            XCTAssertFalse(text.isEmpty, "\(path) is empty")
        }
    }

    /// Criterion 2, structurally: nothing in the validation subsystem can evaluate
    /// Extension code, because nothing in it names anything that could.
    func testManifestValidationSubsystemNamesNoEvaluator() throws {
        for path in Self.subsystemFiles {
            let text = try source(of: path)
            for token in Self.forbiddenTokens {
                XCTAssertFalse(text.contains(token),
                               "\(path) references '\(token)'. Manifest validation must run "
                               + "no Extension code and must not be able to.")
            }
        }
    }

    /// The subsystem imports Foundation and nothing else. A new import is the way an
    /// evaluator would arrive, so the import list itself is pinned.
    func testManifestValidationSubsystemImportsFoundationOnly() throws {
        for path in Self.subsystemFiles {
            let imports = try source(of: path)
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("import ") }
            XCTAssertEqual(imports, ["import Foundation"], "unexpected imports in \(path)")
        }
    }

    // MARK: - Phase 4 criterion 2: a `SourceDeclaration` exists only as the validator's output

    /// ADR-0003 Amendment 4, decision 4: `SourceDeclaration`'s initialiser is inaccessible
    /// outside `SourceDeclarationValidator`, so "must already have passed validation" is a
    /// fact the compiler enforces rather than prose. The compiler is the real guard; this
    /// test pins the *access modifier* the compiler enforces it through, so a later hand
    /// that widens `fileprivate` back to internal goes red here instead of silently
    /// reopening the gap #161 closed.
    func testSourceDeclarationInitialiserIsFilePrivateToTheValidator() throws {
        let validator = try source(of: "MangaCarta/Models/SourceDeclarationValidator.swift")
        XCTAssertTrue(validator.contains("struct SourceDeclaration:"),
                      "SourceDeclaration must be declared in the validator's file — fileprivate "
                      + "is Swift's only way to scope an initialiser to one other type")
        XCTAssertTrue(validator.contains("fileprivate init(qualifiedId: QualifiedSourceID"),
                      "SourceDeclaration's only initialiser must be fileprivate")
    }

    /// The other half of the same claim, in the style of the token scan above: no Swift
    /// file in the app or its tests spells a `SourceDeclaration(` construction other than
    /// the validator. A test that needs one goes through the validator from JSON, as
    /// `ExtensionRuntimeFixtures` now does.
    func testNoFileOutsideTheValidatorConstructsADeclaration() throws {
        // Spelled in two halves so this file does not match its own scan.
        let construction = "SourceDeclaration" + "("
        let roots = ["MangaCarta", "MangaCartaTests", "MangaCartaUITests"]
        var offenders: [String] = []
        for root in roots {
            let directory = repositoryRoot.appendingPathComponent(root)
            guard let enumerator = FileManager.default.enumerator(at: directory,
                                                                  includingPropertiesForKeys: nil) else {
                continue
            }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                if url.lastPathComponent == "SourceDeclarationValidator.swift" { continue }
                let text = try String(contentsOf: url, encoding: .utf8)
                for line in text.split(separator: "\n", omittingEmptySubsequences: false)
                where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
                    && line.contains(construction) {
                    offenders.append("\(url.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertEqual(offenders, [],
                       "only SourceDeclarationValidator may construct a SourceDeclaration")
    }

    /// The behavioural companion to the structural claim: JavaScript that arrives inside
    /// `configuration` — the one place unknown keys survive — comes back out as inert
    /// text, byte for byte, with nothing about the host's own policy disturbed.
    func testJavaScriptInsideConfigurationIsCarriedAsInertText() throws {
        let script = "globalThis.pwned = true; (function(){ return 1 })()"
        let declaration: [String: Any] = [
            "localId": "example", "name": "Example", "engine": "madara",
            "configuration": ["script": script, "entry": ["source": script]],
            "adult": "none",
            "capabilities": ["search": true, "detail": true, "chapters": true,
                             "pages": true, "popular": true],
            "languages": ["mode": "fixed", "values": ["en"]],
            "network": ["httpOrigins": ["https://example.test"]],
            "hostAPI": ["minimum": "1.0", "maximumExclusive": "2.0"]
        ]
        let data = try JSONSerialization.data(withJSONObject: declaration)
        let validated = try SourceDeclarationValidator
            .validate(json: data,
                      qualifiedId: QualifiedSourceID(rawValue: "repo:example"),
                      hostAPI: .v1)
            .get()

        XCTAssertEqual(validated.configuration,
                       .object(["script": .string(script),
                                "entry": .object(["source": .string(script)])]))
        XCTAssertEqual(validated.adult, AdultClassification.none)
    }
}
