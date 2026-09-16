//
//  RepositoryIndexValidatorTests.swift
//  MangaCartaTests
//
//  Contract tests for the format-1 repository index. The index parser owns only
//  repository and bundle shape; declaration bytes remain raw until an installer
//  has minted a qualified identity for SourceDeclarationValidator.
//

import XCTest
@testable import MangaCarta

final class RepositoryIndexValidatorTests: XCTestCase {

    private let indexURL = URL(string: "https://repo.example/index.json")!

    private func declaration(localID: String = "example") -> [String: Any] {
        [
            "localId": localID,
            "name": "Example",
            "engine": "madara",
            "configuration": ["baseURL": "https://example.test"],
            "adult": "none",
            "capabilities": ["search": true, "popular": true, "detail": true,
                             "chapters": true, "pages": true],
            "languages": ["mode": "fixed", "values": ["en"]],
            "network": ["httpOrigins": ["https://example.test"]],
            "hostAPI": ["minimum": "1.0", "maximumExclusive": "2.0"]
        ]
    }

    private func index(bundles: [[String: Any]] = []) -> [String: Any] {
        ["format": 1, "name": "Example Repository", "bundles": bundles]
    }

    private func bundle(id: String = "example-engine",
                        version: Any = 1,
                        script: String = "bundles/example/engine.js",
                        digest: String = String(repeating: "a", count: 64),
                        sources: [[String: Any]]? = nil) -> [String: Any] {
        ["id": id, "version": version, "script": script, "scriptSHA256": digest,
         "sources": sources ?? [declaration()]]
    }

    private func validate(_ object: [String: Any]) throws -> Result<RepositoryIndex, RepositoryIndexError> {
        let data = try JSONSerialization.data(withJSONObject: object)
        return RepositoryIndexValidator.validate(json: data, indexURL: indexURL)
    }

    func testEmptyFormatOneIndexParsesTypedValues() throws {
        let result = try validate(index())
        let parsed = try result.get()

        XCTAssertEqual(parsed.format, 1)
        XCTAssertEqual(parsed.name, "Example Repository")
        XCTAssertTrue(parsed.bundles.isEmpty)
    }

    func testBundleParsesResolvedScriptAndRetainsRawDeclarationForLaterValidation() throws {
        let result = try validate(index(bundles: [bundle()]))
        let parsed = try result.get()
        let parsedBundle = try XCTUnwrap(parsed.bundles.first)

        XCTAssertEqual(parsedBundle.id, "example-engine")
        XCTAssertEqual(parsedBundle.version, 1)
        XCTAssertEqual(parsedBundle.scriptURL.absoluteString,
                       "https://repo.example/bundles/example/engine.js")
        XCTAssertEqual(parsedBundle.scriptSHA256, String(repeating: "a", count: 64))
        XCTAssertEqual(parsedBundle.sources.count, 1)
        XCTAssertEqual(parsedBundle.sources[0].localID, "example")
        XCTAssertEqual(parsedBundle.sources[0].rawJSON.objectValue?["engine"], .string("madara"))
    }

    func testDeclarationValidationIsDelegatedFromRawJSONAfterIdentityIsMinted() throws {
        let parsed = try validate(index(bundles: [bundle()])).get()
        let record = try XCTUnwrap(parsed.bundles[0].sources.first)
        let qualifiedID = QualifiedSourceID(rawValue: "repo-uuid:example")

        let declaration = try record.validate(qualifiedId: qualifiedID).get()
        XCTAssertEqual(declaration.qualifiedId, qualifiedID)
        XCTAssertEqual(declaration.localId, "example")
    }

    func testWrongRootAndMissingKeysNameTheirPaths() throws {
        let scalar = try RepositoryIndexValidator.validate(json: Data("true".utf8), indexURL: indexURL)
        XCTAssertEqual(scalar, .failure(.notAnObject(path: "")))

        let malformed = RepositoryIndexValidator.validate(json: Data("{not-json".utf8), indexURL: indexURL)
        if case .failure(.malformedJSON) = malformed {
            // The parser reports Foundation's detail, but the failure must remain typed.
        } else {
            XCTFail("malformed JSON must be rejected as malformedJSON")
        }

        let missing = try validate(["format": 1, "bundles": []])
        XCTAssertEqual(missing, .failure(.missingKey(path: "name")))
    }

    func testUnknownAndWrongTypedKeysAreLocated() throws {
        var unknown = index()
        unknown["future"] = true
        XCTAssertEqual(try validate(unknown), .failure(.unknownKey(path: "", key: "future")))

        var wrong = index()
        wrong["bundles"] = "none"
        XCTAssertEqual(try validate(wrong), .failure(.wrongType(path: "bundles", expected: "array")))
    }

    func testFormatIsAnIntegerVersionAxisAndOnlyFormatOneIsSupported() throws {
        var wrongType = index()
        wrongType["format"] = "1.0"
        XCTAssertEqual(try validate(wrongType), .failure(.wrongType(path: "format", expected: "integer")))

        var unsupported = index()
        unsupported["format"] = 2
        XCTAssertEqual(try validate(unsupported), .failure(.unsupportedFormat(path: "format", value: 2)))

        var nonPositive = index()
        nonPositive["format"] = 0
        XCTAssertEqual(try validate(nonPositive), .failure(.invalidFormat(path: "format", value: 0)))
    }

    func testBundleIdentityVersionAndDigestRulesAreEnforced() throws {
        var invalidID = index(bundles: [bundle(id: "Not-valid")])
        XCTAssertEqual(try validate(invalidID), .failure(.invalidBundleID(path: "bundles.0.id", value: "Not-valid")))

        var duplicateIDs = index(bundles: [bundle(), bundle()])
        XCTAssertEqual(try validate(duplicateIDs), .failure(.duplicateBundleID(id: "example-engine",
                                                                                firstPath: "bundles.0.id",
                                                                                secondPath: "bundles.1.id")))

        var badVersion = index(bundles: [bundle(version: 0)])
        XCTAssertEqual(try validate(badVersion), .failure(.invalidBundleVersion(path: "bundles.0.version", value: "0")))

        var badDigest = index(bundles: [bundle(digest: String(repeating: "A", count: 64))])
        XCTAssertEqual(try validate(badDigest), .failure(.invalidScriptSHA256(path: "bundles.0.scriptSHA256",
                                                                                 value: String(repeating: "A", count: 64))))
    }

    func testScriptResolvesOnlyToPolicyValidHTTPSURL() throws {
        var insecure = index(bundles: [bundle(script: "http://repo.example/engine.js")])
        let insecureResult = try validate(insecure)
        XCTAssertEqual(insecureResult,
                       .failure(.invalidScriptURL(path: "bundles.0.script",
                                                  value: "http://repo.example/engine.js",
                                                  reason: "only absolute HTTPS URLs are allowed")))
        XCTAssertTrue(insecureResult.failureMessage.contains("bundles.0.script"))

        var privateHost = index(bundles: [bundle(script: "https://127.0.0.1/engine.js")])
        XCTAssertEqual(try validate(privateHost),
                       .failure(.invalidScriptURL(path: "bundles.0.script",
                                                  value: "https://127.0.0.1/engine.js",
                                                  reason: "loopback destinations are not reachable")))
    }

    func testSourcesMustBeNonEmptyObjectsAndLocalIDsAreUniqueAcrossBundles() throws {
        var empty = index(bundles: [bundle(sources: [])])
        XCTAssertEqual(try validate(empty), .failure(.emptySources(path: "bundles.0.sources")))

        var duplicateLocalIDs = index(bundles: [bundle(), bundle(id: "second-engine")])
        XCTAssertEqual(try validate(duplicateLocalIDs),
                       .failure(.duplicateLocalID(localID: "example",
                                                  firstPath: "bundles.0.sources.0.localId",
                                                  secondPath: "bundles.1.sources.0.localId")))
    }

    func testNameIsTrimmedAndBoundedByUnicodeScalars() throws {
        var trimmed = index()
        trimmed["name"] = "  Repository  "
        XCTAssertEqual(try validate(trimmed).get().name, "Repository")

        var empty = index()
        empty["name"] = " \n\t "
        XCTAssertEqual(try validate(empty), .failure(.invalidRepositoryName(reason: .empty)))

        var tooLong = index()
        tooLong["name"] = String(repeating: "é", count: 81)
        XCTAssertEqual(try validate(tooLong), .failure(.invalidRepositoryName(reason: .tooLong)))
    }

    func testIndexSizeIsBoundedBeforeDecoding() {
        let data = Data(repeating: 0x20, count: RepositoryFormatLimits.maximumIndexBytes + 1)
        let result = RepositoryIndexValidator.validate(json: data, indexURL: indexURL)
        XCTAssertEqual(result,
                       .failure(.exceedsSizeLimit(path: "<document>",
                                                  actualBytes: data.count,
                                                  maximumBytes: RepositoryFormatLimits.maximumIndexBytes)))
    }

    func testMalformedBundleAndSourceShapesNameArrayPaths() throws {
        var malformedBundle = index()
        malformedBundle["bundles"] = ["not-an-object"]
        XCTAssertEqual(try validate(malformedBundle),
                       .failure(.wrongType(path: "bundles.0", expected: "object")))

        var malformedSource = index()
        // The inner array intentionally contains no object; it exercises the record seam.
        var sourceBundle = bundle()
        sourceBundle["sources"] = ["not-an-object"]
        malformedSource["bundles"] = [sourceBundle]
        XCTAssertEqual(try validate(malformedSource),
                       .failure(.wrongType(path: "bundles.0.sources.0", expected: "object")))
    }
}

private extension Result where Failure == RepositoryIndexError {
    var failureMessage: String {
        guard case .failure(let error) = self else { return "" }
        return error.message
    }
}
