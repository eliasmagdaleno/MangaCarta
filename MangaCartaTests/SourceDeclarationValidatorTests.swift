//
//  SourceDeclarationValidatorTests.swift
//  MangaCartaTests
//
//  Validation of a bundle's Source declarations, per the Host API design's
//  "Source declaration", "Entry points", "Versions and feature negotiation",
//  "Language contract", "URL policy", "Adult classification" and
//  "Source-authored presentation" sections.
//
//  Two rules drive most of this suite and are easy to get backwards:
//
//  * unknown keys are ignored ONLY inside `configuration` — anywhere else they
//    fail installation, so a misspelling cannot silently disable policy; and
//  * `adult` is fail-closed — absent or unrecognized is a rejection, never `none`.
//

import XCTest
@testable import MangaCarta

final class SourceDeclarationValidatorTests: XCTestCase {

    private static let qualifiedId = QualifiedSourceID(rawValue: "repo-7f2a:example-madara-site")

    // MARK: - Fixtures

    /// The canonical declaration from the design's "Source declaration" section, plus the
    /// `hostAPI` range that section's example omits but "Versions and feature negotiation"
    /// requires. Every rejection test below mutates exactly one thing about this record.
    private func baseDeclaration() -> [String: Any] {
        [
            "localId": "example-madara-site",
            "name": "Example Manga",
            "engine": "madara",
            "configuration": ["baseURL": "https://example.test"],
            "adult": "none",
            "capabilities": [
                "search": true, "popular": true, "newTitles": false,
                "latestUpdates": true, "detail": true, "chapters": true,
                "pages": true, "tagBrowse": false, "webURL": true
            ],
            "languages": ["mode": "fixed", "values": ["en"]],
            "network": [
                "httpOrigins": ["https://example.test"],
                "browserOrigins": ["https://example.test"],
                "assetOrigins": ["https://cdn.example.test"]
            ],
            "presentation": [
                "feeds": [
                    "popular": ["title": "Popular"],
                    "latestUpdates": ["title": "Recently Updated", "badge": "new"]
                ],
                "imagePrefetchConcurrency": 4
            ],
            "hostAPI": ["minimum": "1.0", "maximumExclusive": "2.0"]
        ]
    }

    private func declaration(setting key: String, to value: Any?) -> [String: Any] {
        var dict = baseDeclaration()
        if let value { dict[key] = value } else { dict.removeValue(forKey: key) }
        return dict
    }

    private func result(_ dict: [String: Any],
                        hostAPI: HostAPISupport = .v1) throws -> Result<SourceDeclaration, SourceDeclarationError> {
        let data = try JSONSerialization.data(withJSONObject: dict)
        return SourceDeclarationValidator.validate(json: data,
                                                   qualifiedId: Self.qualifiedId,
                                                   hostAPI: hostAPI)
    }

    @discardableResult
    private func accepted(_ dict: [String: Any],
                          hostAPI: HostAPISupport = .v1,
                          file: StaticString = #filePath,
                          line: UInt = #line) throws -> SourceDeclaration {
        switch try result(dict, hostAPI: hostAPI) {
        case .success(let declaration):
            return declaration
        case .failure(let error):
            XCTFail("expected acceptance, got \(error)", file: file, line: line)
            throw error
        }
    }

    @discardableResult
    private func rejected(_ dict: [String: Any],
                          hostAPI: HostAPISupport = .v1,
                          file: StaticString = #filePath,
                          line: UInt = #line) throws -> SourceDeclarationError {
        switch try result(dict, hostAPI: hostAPI) {
        case .success(let declaration):
            XCTFail("expected rejection, got \(declaration.localId)", file: file, line: line)
            throw SourceDeclarationError.notAnObject(path: "")
        case .failure(let error):
            return error
        }
    }

    // MARK: - Happy path

    func testCanonicalDeclarationValidates() throws {
        let declaration = try accepted(baseDeclaration())

        XCTAssertEqual(declaration.qualifiedId, Self.qualifiedId)
        XCTAssertEqual(declaration.localId, "example-madara-site")
        XCTAssertEqual(declaration.name, "Example Manga")
        XCTAssertEqual(declaration.engine, "madara")
        XCTAssertEqual(declaration.adult, AdultClassification.none)
        XCTAssertTrue(declaration.capabilities.supports(.search))
        XCTAssertFalse(declaration.capabilities.supports(.newTitles))
        XCTAssertEqual(declaration.languages.mode, .fixed)
        XCTAssertEqual(declaration.languages.tags, ["en"])
        XCTAssertEqual(declaration.network.httpOrigins, ["https://example.test"])
        XCTAssertEqual(declaration.network.assetOrigins, ["https://cdn.example.test"])
        XCTAssertEqual(declaration.presentation.feeds[.popular]?.title, "Popular")
        XCTAssertEqual(declaration.presentation.feeds[.latestUpdates]?.badge, .new)
        XCTAssertEqual(declaration.presentation.imagePrefetchConcurrencyHint, 4)
        XCTAssertEqual(declaration.selectedHostAPIVersion, HostAPIVersion(major: 1, minor: 2))
        XCTAssertEqual(declaration.configuration,
                       .object(["baseURL": .string("https://example.test")]))
        XCTAssertEqual(declaration.externalIds, [])
    }

    func testExternalIDsAreOptionalAndValidated() throws {
        var acceptedJSON = baseDeclaration()
        acceptedJSON["externalIds"] = ["mal"]
        var acceptedCapabilities = try XCTUnwrap(acceptedJSON["capabilities"] as? [String: Any])
        acceptedCapabilities["listing"] = true
        acceptedJSON["capabilities"] = acceptedCapabilities
        XCTAssertEqual(try accepted(acceptedJSON).externalIds, ["mal"])

        XCTAssertEqual(try rejected(declaration(setting: "externalIds", to: ["mal", "mal"])),
                       .duplicateExternalIDNamespace("mal"))
        XCTAssertEqual(try rejected(declaration(setting: "externalIds", to: ["anilist"])),
                       .unknownExternalIDNamespace("anilist"))

        var withoutListing = baseDeclaration()
        withoutListing["externalIds"] = ["mal"]
        XCTAssertEqual(try rejected(withoutListing), .externalIDsRequireListing)
    }

    func testExternalIDFeaturesRequireHostAPI11() throws {
        var legacy = baseDeclaration()
        legacy["hostAPI"] = ["minimum": "1.0", "maximumExclusive": "1.1"]
        legacy["externalIds"] = ["mal"]
        XCTAssertEqual(try rejected(legacy),
                       .featureRequiresHostAPIVersion(feature: "externalIds",
                                                      minimum: HostAPIVersion(major: 1, minor: 1),
                                                      selected: HostAPIVersion(major: 1, minor: 0)))

        var legacyListing = baseDeclaration()
        legacyListing["hostAPI"] = ["minimum": "1.0", "maximumExclusive": "1.1"]
        var capabilities = try XCTUnwrap(legacyListing["capabilities"] as? [String: Any])
        capabilities["listing"] = true
        legacyListing["capabilities"] = capabilities
        XCTAssertEqual(try rejected(legacyListing),
                       .featureRequiresHostAPIVersion(feature: "capabilities.listing",
                                                      minimum: HostAPIVersion(major: 1, minor: 1),
                                                      selected: HostAPIVersion(major: 1, minor: 0)))

        var current = baseDeclaration()
        current["hostAPI"] = ["minimum": "1.1", "maximumExclusive": "2.0"]
        current["externalIds"] = ["mal"]
        var currentCapabilities = try XCTUnwrap(current["capabilities"] as? [String: Any])
        currentCapabilities["listing"] = true
        current["capabilities"] = currentCapabilities
        let acceptedCurrent = try accepted(current)
        XCTAssertEqual(acceptedCurrent.selectedHostAPIVersion, HostAPIVersion(major: 1, minor: 2))

        var legacyNoFeature = legacy
        legacyNoFeature.removeValue(forKey: "externalIds")
        XCTAssertNoThrow(try accepted(legacyNoFeature))
    }

    /// The id is supplied by the installer and copied through untouched. Nothing in the
    /// declaration — least of all the display `name` — participates in identity.
    func testQualifiedIdIsTakenFromTheInstallerAndNameIsNotIdentity() throws {
        let renamed = declaration(setting: "name", to: "Totally Different Name")
        let first = try accepted(baseDeclaration())
        let second = try accepted(renamed)

        XCTAssertEqual(first.qualifiedId, second.qualifiedId)
        XCTAssertEqual(second.qualifiedId.rawValue, "repo-7f2a:example-madara-site")
        XCTAssertNotEqual(first.name, second.name)
    }

    func testMalformedJSONIsRejected() {
        let garbage = Data("{ not json".utf8)
        switch SourceDeclarationValidator.validate(json: garbage,
                                                   qualifiedId: Self.qualifiedId,
                                                   hostAPI: .v1) {
        case .success:
            XCTFail("expected malformed JSON to be rejected")
        case .failure(let error):
            guard case .malformedJSON = error else {
                return XCTFail("expected .malformedJSON, got \(error)")
            }
        }
    }

    func testNonObjectDeclarationIsRejected() throws {
        let data = try JSONSerialization.data(withJSONObject: ["not", "an", "object"])
        switch SourceDeclarationValidator.validate(json: data,
                                                   qualifiedId: Self.qualifiedId,
                                                   hostAPI: .v1) {
        case .success:
            XCTFail("expected a top-level array to be rejected")
        case .failure(let error):
            XCTAssertEqual(error, .notAnObject(path: ""))
        }
    }

    // MARK: - Unknown keys fail everywhere outside `configuration`

    func testUnknownTopLevelKeyIsRejected() throws {
        let error = try rejected(declaration(setting: "adultt", to: "none"))
        XCTAssertEqual(error, .unknownKey(path: "", key: "adultt"))
    }

    func testUnknownKeyInsideCapabilitiesIsRejected() throws {
        var capabilities = baseDeclaration()["capabilities"] as? [String: Any] ?? [:]
        capabilities["serach"] = true
        let error = try rejected(declaration(setting: "capabilities", to: capabilities))
        XCTAssertEqual(error, .unknownKey(path: "capabilities", key: "serach"))
    }

    func testUnknownKeyInsideLanguagesIsRejected() throws {
        let languages: [String: Any] = ["mode": "fixed", "values": ["en"], "default": "en"]
        let error = try rejected(declaration(setting: "languages", to: languages))
        XCTAssertEqual(error, .unknownKey(path: "languages", key: "default"))
    }

    func testUnknownKeyInsideNetworkIsRejected() throws {
        let network: [String: Any] = ["httpOrigins": ["https://example.test"],
                                      "imageOrigins": ["https://cdn.example.test"]]
        let error = try rejected(declaration(setting: "network", to: network))
        XCTAssertEqual(error, .unknownKey(path: "network", key: "imageOrigins"))
    }

    func testUnknownKeyInsidePresentationIsRejected() throws {
        let presentation: [String: Any] = ["feeds": [:], "railOrder": ["popular"]]
        let error = try rejected(declaration(setting: "presentation", to: presentation))
        XCTAssertEqual(error, .unknownKey(path: "presentation", key: "railOrder"))
    }

    func testUnknownKeyInsideFeedRecordIsRejected() throws {
        let presentation: [String: Any] = ["feeds": ["popular": ["title": "Popular", "tint": "red"]]]
        let error = try rejected(declaration(setting: "presentation", to: presentation))
        XCTAssertEqual(error, .unknownKey(path: "presentation.feeds.popular", key: "tint"))
    }

    func testUnknownKeyInsideHostAPIIsRejected() throws {
        let hostAPI: [String: Any] = ["minimum": "1.0", "maximumExclusive": "2.0", "preferred": "1.0"]
        let error = try rejected(declaration(setting: "hostAPI", to: hostAPI))
        XCTAssertEqual(error, .unknownKey(path: "hostAPI", key: "preferred"))
    }

    /// The other direction of the asymmetry: `configuration` is the engine's private
    /// vocabulary, so arbitrary nested keys survive validation byte-for-byte and inert.
    func testUnknownKeysInsideConfigurationAreKeptVerbatim() throws {
        let configuration: [String: Any] = [
            "baseURL": "https://example.test",
            "selectors": ["card": ".manga", "nested": ["deep": [1, 2, 3]]],
            "adult": "adultOnly",
            "capabilities": ["search": false],
            "anythingAtAll": true
        ]
        let declaration = try accepted(self.declaration(setting: "configuration", to: configuration))

        XCTAssertEqual(declaration.configuration, .object([
            "baseURL": .string("https://example.test"),
            "selectors": .object(["card": .string(".manga"),
                                  "nested": .object(["deep": .array([.int(1), .int(2), .int(3)])])]),
            "adult": .string("adultOnly"),
            "capabilities": .object(["search": .bool(false)]),
            "anythingAtAll": .bool(true)
        ]))
        // Host-owned policy is unmoved by look-alike keys inside configuration.
        XCTAssertEqual(declaration.adult, AdultClassification.none)
        XCTAssertTrue(declaration.capabilities.supports(.search))
    }

    func testMissingConfigurationMeansNoConfiguration() throws {
        let declaration = try accepted(self.declaration(setting: "configuration", to: nil))
        XCTAssertEqual(declaration.configuration, .object([:]))
    }

    func testNonObjectConfigurationIsRejected() throws {
        let error = try rejected(declaration(setting: "configuration", to: ["a", "b"]))
        XCTAssertEqual(error, .wrongType(path: "configuration", expected: "object"))
    }

    // MARK: - localId

    func testLocalIdAcceptsLowercaseAlphanumericsDashAndDot() throws {
        for id in ["a", "example-madara-site", "site.co.example", "abc123", "1", String(repeating: "z", count: 64)] {
            let declaration = try accepted(self.declaration(setting: "localId", to: id))
            XCTAssertEqual(declaration.localId, id)
        }
    }

    func testLocalIdRejectsAnythingOutsideItsCharacterSet() throws {
        for id in ["Example", "under_score", "has space", "sla/sh", "emoji🙂", "caf\u{00E9}", "plus+"] {
            let error = try rejected(declaration(setting: "localId", to: id))
            XCTAssertEqual(error, .invalidLocalID(id), "expected \(id) to be refused")
        }
    }

    func testLocalIdLengthIsBounded() throws {
        XCTAssertEqual(try rejected(declaration(setting: "localId", to: "")), .invalidLocalID(""))
        let tooLong = String(repeating: "z", count: 65)
        XCTAssertEqual(try rejected(declaration(setting: "localId", to: tooLong)), .invalidLocalID(tooLong))
    }

    func testLocalIdIsRequired() throws {
        XCTAssertEqual(try rejected(declaration(setting: "localId", to: nil)), .missingKey(path: "localId"))
    }

    // MARK: - name

    func testNameIsTrimmed() throws {
        let declaration = try accepted(self.declaration(setting: "name", to: "  Example Manga \n"))
        XCTAssertEqual(declaration.name, "Example Manga")
    }

    func testEmptyOrWhitespaceOnlyNameIsRejected() throws {
        for name in ["", "   ", "\n\t"] {
            let error = try rejected(declaration(setting: "name", to: name))
            XCTAssertEqual(error, .invalidName(reason: .empty))
        }
    }

    func testNameLengthIsBoundedInUnicodeScalars() throws {
        let atLimit = String(repeating: "e", count: 80)
        XCTAssertEqual(try accepted(declaration(setting: "name", to: atLimit)).name, atLimit)

        let overLimit = String(repeating: "e", count: 81)
        XCTAssertEqual(try rejected(declaration(setting: "name", to: overLimit)),
                       .invalidName(reason: .tooLong))
    }

    func testNameIsRequiredAndMustBeAString() throws {
        XCTAssertEqual(try rejected(declaration(setting: "name", to: nil)), .missingKey(path: "name"))
        XCTAssertEqual(try rejected(declaration(setting: "name", to: 7)),
                       .wrongType(path: "name", expected: "string"))
    }

    // MARK: - engine

    func testEngineIsRequiredNonEmptyAndBounded() throws {
        XCTAssertEqual(try accepted(declaration(setting: "engine", to: " madara ")).engine, "madara")
        XCTAssertEqual(try rejected(declaration(setting: "engine", to: nil)), .missingKey(path: "engine"))
        XCTAssertEqual(try rejected(declaration(setting: "engine", to: "  ")), .invalidEngine("  "))
        let tooLong = String(repeating: "e", count: 65)
        XCTAssertEqual(try rejected(declaration(setting: "engine", to: tooLong)), .invalidEngine(tooLong))
    }

    // MARK: - adult (fail-closed)

    func testAdultAcceptsExactlyThreeClassifications() throws {
        let cases: [(String, AdultClassification)] = [
            ("none", .none), ("mixed", .mixed), ("adultOnly", .adultOnly)
        ]
        for (raw, expected) in cases {
            XCTAssertEqual(try accepted(declaration(setting: "adult", to: raw)).adult, expected)
        }
    }

    /// The single most important fail-closed rule in the declaration: absence is a
    /// rejection, never a quiet default to `none`.
    func testMissingAdultClassificationIsRejectedRatherThanDefaultedToNone() throws {
        let error = try rejected(declaration(setting: "adult", to: nil))
        XCTAssertEqual(error, .missingKey(path: "adult"))
    }

    func testUnrecognizedAdultClassificationIsRejected() throws {
        for raw in ["safe", "None", "ADULTONLY", "adult_only", "true", ""] {
            XCTAssertEqual(try rejected(declaration(setting: "adult", to: raw)),
                           .invalidAdultClassification(raw))
        }
    }

    func testNonStringAdultClassificationIsRejected() throws {
        XCTAssertEqual(try rejected(declaration(setting: "adult", to: false)),
                       .wrongType(path: "adult", expected: "string"))
    }

    // MARK: - capabilities and registration invariants

    func testMissingCapabilityFlagMeansUnsupported() throws {
        let capabilities: [String: Any] = ["search": true, "detail": true, "chapters": true,
                                           "pages": true, "popular": true]
        var dict = self.declaration(setting: "capabilities", to: capabilities)
        dict["presentation"] = ["feeds": ["popular": ["title": "Popular"]]]
        let declaration = try accepted(dict)
        XCTAssertTrue(declaration.capabilities.supports(.popular))
        XCTAssertFalse(declaration.capabilities.supports(.tagBrowse))
        XCTAssertFalse(declaration.capabilities.supports(.webURL))
    }

    func testNonBooleanCapabilityFlagIsRejected() throws {
        var capabilities = baseDeclaration()["capabilities"] as? [String: Any] ?? [:]
        capabilities["search"] = "yes"
        XCTAssertEqual(try rejected(declaration(setting: "capabilities", to: capabilities)),
                       .wrongType(path: "capabilities.search", expected: "boolean"))
    }

    func testCapabilitiesAreRequiredAndMustBeAnObject() throws {
        XCTAssertEqual(try rejected(declaration(setting: "capabilities", to: nil)),
                       .missingKey(path: "capabilities"))
        XCTAssertEqual(try rejected(declaration(setting: "capabilities", to: ["search"])),
                       .wrongType(path: "capabilities", expected: "object"))
    }

    /// Browsable/readable requires all four of search, detail, chapters and pages.
    func testEachMissingReadingCapabilityPreventsRegistration() throws {
        for missing in ["search", "detail", "chapters", "pages"] {
            var capabilities = baseDeclaration()["capabilities"] as? [String: Any] ?? [:]
            capabilities[missing] = false
            let error = try rejected(declaration(setting: "capabilities", to: capabilities))
            XCTAssertEqual(error, .missingRequiredCapabilities([missing]),
                           "expected a declaration without \(missing) to be refused")
        }
    }

    func testMissingSeveralReadingCapabilitiesNamesThemAllInOperationOrder() throws {
        var capabilities = baseDeclaration()["capabilities"] as? [String: Any] ?? [:]
        capabilities["chapters"] = false
        capabilities["search"] = false
        let error = try rejected(declaration(setting: "capabilities", to: capabilities))
        XCTAssertEqual(error, .missingRequiredCapabilities(["search", "chapters"]))
    }

    /// Home discovery requires at least one of popular, newTitles or latestUpdates.
    func testDeclarationWithNoDiscoveryFeedIsNotRegistered() throws {
        var capabilities = baseDeclaration()["capabilities"] as? [String: Any] ?? [:]
        capabilities["popular"] = false
        capabilities["newTitles"] = false
        capabilities["latestUpdates"] = false
        var declaration = self.declaration(setting: "capabilities", to: capabilities)
        declaration["presentation"] = ["feeds": [:]]
        XCTAssertEqual(try rejected(declaration), .noDiscoveryCapability)
    }

    func testAnySingleDiscoveryFeedSatisfiesTheInvariant() throws {
        for feed in ["popular", "newTitles", "latestUpdates"] {
            var capabilities = baseDeclaration()["capabilities"] as? [String: Any] ?? [:]
            for other in ["popular", "newTitles", "latestUpdates"] { capabilities[other] = false }
            capabilities[feed] = true
            var declaration = self.declaration(setting: "capabilities", to: capabilities)
            declaration["presentation"] = ["feeds": [:]]
            XCTAssertNoThrow(try accepted(declaration), "expected \(feed) alone to suffice")
        }
    }

    // MARK: - languages

    func testEachLanguageModeIsAccepted() throws {
        for (raw, expected): (String, LanguageMode) in [("fixed", .fixed), ("selectable", .selectable), ("mixed", .mixed)] {
            let languages: [String: Any] = ["mode": raw, "values": ["en"]]
            XCTAssertEqual(try accepted(declaration(setting: "languages", to: languages)).languages.mode,
                           expected)
        }
    }

    func testUnknownOrMissingLanguageModeIsRejected() throws {
        XCTAssertEqual(try rejected(declaration(setting: "languages", to: ["values": ["en"]])),
                       .missingKey(path: "languages.mode"))
        XCTAssertEqual(try rejected(declaration(setting: "languages", to: ["mode": "auto", "values": ["en"]])),
                       .invalidLanguageMode("auto"))
    }

    func testLanguagesIsRequired() throws {
        XCTAssertEqual(try rejected(declaration(setting: "languages", to: nil)),
                       .missingKey(path: "languages"))
    }

    func testLanguageTagsAreCanonicalisedNotSubstituted() throws {
        let languages: [String: Any] = ["mode": "selectable",
                                        "values": ["EN-us", "pt-br", "zh-hant", "ja"]]
        let declaration = try accepted(self.declaration(setting: "languages", to: languages))
        XCTAssertEqual(declaration.languages.tags, ["en-US", "pt-BR", "zh-Hant", "ja"])
    }

    func testIllFormedLanguageTagIsRejected() throws {
        for tag in ["english", "e", "en_US", "en-", "-en", "en--US", "en US", "1234", "", "en-USA-"] {
            XCTAssertEqual(try rejected(declaration(setting: "languages",
                                                    to: ["mode": "fixed", "values": [tag]])),
                           .invalidLanguageTag(tag), "expected '\(tag)' to be refused")
        }
    }

    func testEmptyLanguageValuesIsRejected() throws {
        XCTAssertEqual(try rejected(declaration(setting: "languages",
                                                to: ["mode": "mixed", "values": [String]()])),
                       .emptyLanguageValues)
        XCTAssertEqual(try rejected(declaration(setting: "languages", to: ["mode": "mixed"])),
                       .missingKey(path: "languages.values"))
    }

    func testDuplicateLanguageTagsAreRejectedAfterCanonicalisation() throws {
        XCTAssertEqual(try rejected(declaration(setting: "languages",
                                                to: ["mode": "fixed", "values": ["en", "EN"]])),
                       .duplicateLanguageTag("en"))
    }

    // MARK: - network origins

    func testOriginsAreCanonicalised() throws {
        let network: [String: Any] = ["httpOrigins": ["HTTPS://Example.TEST/", "https://example.test:8443"],
                                      "browserOrigins": [],
                                      "assetOrigins": []]
        let declaration = try accepted(self.declaration(setting: "network", to: network))
        XCTAssertEqual(declaration.network.httpOrigins,
                       ["https://example.test", "https://example.test:8443"])
    }

    func testNonHTTPSOriginsAreRejected() throws {
        for origin in ["http://example.test", "file:///etc/passwd", "data:text/plain,hi",
                       "javascript:alert(1)", "ftp://example.test", "example.test",
                       "//example.test", "https://"] {
            let network: [String: Any] = ["httpOrigins": [origin]]
            let error = try rejected(declaration(setting: "network", to: network))
            guard case .invalidOrigin(let path, let value, _) = error else {
                return XCTFail("expected .invalidOrigin for \(origin), got \(error)")
            }
            XCTAssertEqual(path, "network.httpOrigins")
            XCTAssertEqual(value, origin)
        }
    }

    func testOriginsCarryingPathQueryFragmentOrCredentialsAreRejected() throws {
        for origin in ["https://example.test/manga", "https://example.test/?q=1",
                       "https://example.test#top", "https://user:pw@example.test"] {
            let network: [String: Any] = ["httpOrigins": [origin]]
            let error = try rejected(declaration(setting: "network", to: network))
            guard case .invalidOrigin = error else {
                return XCTFail("expected .invalidOrigin for \(origin), got \(error)")
            }
        }
    }

    /// The URL-policy section rejects loopback, link-local, multicast and private
    /// destinations. A literal address in the declaration never needs DNS to be caught.
    func testLoopbackAndPrivateLiteralOriginsAreRejected() throws {
        for origin in ["https://127.0.0.1", "https://localhost", "https://192.168.1.1",
                       "https://10.0.0.1", "https://169.254.1.1", "https://[::1]"] {
            let network: [String: Any] = ["httpOrigins": [origin]]
            let error = try rejected(declaration(setting: "network", to: network))
            guard case .invalidOrigin = error else {
                return XCTFail("expected .invalidOrigin for \(origin), got \(error)")
            }
        }
    }

    /// An omitted origin list denies that role rather than opening it.
    func testOmittedOriginListDeniesThatRole() throws {
        let declaration = try accepted(self.declaration(setting: "network",
                                                        to: ["httpOrigins": ["https://example.test"]]))
        XCTAssertEqual(declaration.network.httpOrigins, ["https://example.test"])
        XCTAssertTrue(declaration.network.browserOrigins.isEmpty)
        XCTAssertTrue(declaration.network.assetOrigins.isEmpty)
    }

    func testNetworkIsRequired() throws {
        XCTAssertEqual(try rejected(declaration(setting: "network", to: nil)),
                       .missingKey(path: "network"))
    }

    func testDuplicateOriginsAreRejected() throws {
        let network: [String: Any] = ["httpOrigins": ["https://example.test", "https://EXAMPLE.test/"]]
        XCTAssertEqual(try rejected(declaration(setting: "network", to: network)),
                       .duplicateOrigin(path: "network.httpOrigins", value: "https://example.test"))
    }

    // MARK: - presentation

    func testFeedPresentationIsParsedAndBadgeDefaultsToNone() throws {
        let presentation: [String: Any] = ["feeds": [
            "popular": ["title": "  Popular  ", "eyebrow": "Top rated"],
            "latestUpdates": ["title": "Recently Updated", "badge": "new"]
        ]]
        let declaration = try accepted(self.declaration(setting: "presentation", to: presentation))
        XCTAssertEqual(declaration.presentation.feeds[.popular]?.title, "Popular")
        XCTAssertEqual(declaration.presentation.feeds[.popular]?.eyebrow, "Top rated")
        XCTAssertEqual(declaration.presentation.feeds[.popular]?.badge, FeedBadge.none)
        XCTAssertEqual(declaration.presentation.feeds[.latestUpdates]?.badge, .new)
        XCTAssertNil(declaration.presentation.imagePrefetchConcurrencyHint)
    }

    func testInvalidBadgeIsRejected() throws {
        let presentation: [String: Any] = ["feeds": ["popular": ["badge": "hot"]]]
        XCTAssertEqual(try rejected(declaration(setting: "presentation", to: presentation)),
                       .invalidBadge("hot"))
    }

    func testPresentationTextIsTrimmedAndLengthBounded() throws {
        let overLimit = String(repeating: "p", count: 81)
        let presentation: [String: Any] = ["feeds": ["popular": ["title": overLimit]]]
        XCTAssertEqual(try rejected(declaration(setting: "presentation", to: presentation)),
                       .invalidPresentationText(path: "presentation.feeds.popular.title", reason: .tooLong))

        let blank: [String: Any] = ["feeds": ["popular": ["eyebrow": "   "]]]
        XCTAssertEqual(try rejected(declaration(setting: "presentation", to: blank)),
                       .invalidPresentationText(path: "presentation.feeds.popular.eyebrow", reason: .empty))
    }

    /// Presentation is keyed by feed operation. Non-feed operations have no rail.
    func testPresentationKeyedByANonFeedOperationIsRejected() throws {
        for key in ["search", "detail", "chapters", "pages", "webURL", "tagBrowse", "popluar"] {
            let presentation: [String: Any] = ["feeds": [key: ["title": "X"]]]
            XCTAssertEqual(try rejected(declaration(setting: "presentation", to: presentation)),
                           .unknownFeedKey(key), "expected '\(key)' to be refused as a feed key")
        }
    }

    /// "A capability absent from the declaration has no presentation record."
    func testPresentationForAnUndeclaredCapabilityIsRejected() throws {
        let presentation: [String: Any] = ["feeds": ["newTitles": ["title": "New"]]]
        XCTAssertEqual(try rejected(declaration(setting: "presentation", to: presentation)),
                       .presentationForUndeclaredCapability(.newTitles))
    }

    func testMissingPresentationIsAllowed() throws {
        let declaration = try accepted(self.declaration(setting: "presentation", to: nil))
        XCTAssertTrue(declaration.presentation.feeds.isEmpty)
        XCTAssertNil(declaration.presentation.imagePrefetchConcurrencyHint)
    }

    /// The concurrency value is a hint the host clamps, not an instruction it obeys or
    /// refuses. Out-of-range values are clamped; only a non-integer is a contract error.
    func testImagePrefetchConcurrencyIsClampedRatherThanRejected() throws {
        let range = SourceDeclarationLimits.imagePrefetchConcurrency
        let cases: [(Any, Int)] = [(1, range.lowerBound),
                                   (0, range.lowerBound),
                                   (-4, range.lowerBound),
                                   (4, 4),
                                   (10_000, range.upperBound)]
        for (raw, expected) in cases {
            let presentation: [String: Any] = ["feeds": [:], "imagePrefetchConcurrency": raw]
            let declaration = try accepted(self.declaration(setting: "presentation", to: presentation))
            XCTAssertEqual(declaration.presentation.imagePrefetchConcurrencyHint, expected,
                           "expected \(raw) to clamp to \(expected)")
        }
    }

    func testNonIntegerImagePrefetchConcurrencyIsRejected() throws {
        for raw: Any in ["4", 4.5, true] {
            let presentation: [String: Any] = ["feeds": [:], "imagePrefetchConcurrency": raw]
            XCTAssertEqual(try rejected(declaration(setting: "presentation", to: presentation)),
                           .wrongType(path: "presentation.imagePrefetchConcurrency", expected: "integer"))
        }
    }

    // MARK: - hostAPI range (acceptance criterion 9)

    /// The design's canonical example omits `hostAPI`, but the versions section makes the
    /// range required. Required wins: an omitted range is a rejection, not an assumed v1.
    func testHostAPIRangeIsRequired() throws {
        XCTAssertEqual(try rejected(declaration(setting: "hostAPI", to: nil)),
                       .missingKey(path: "hostAPI"))
        XCTAssertEqual(try rejected(declaration(setting: "hostAPI", to: ["minimum": "1.0"])),
                       .missingKey(path: "hostAPI.maximumExclusive"))
        XCTAssertEqual(try rejected(declaration(setting: "hostAPI", to: ["maximumExclusive": "2.0"])),
                       .missingKey(path: "hostAPI.minimum"))
    }

    func testMalformedHostAPIVersionStringIsRejected() throws {
        XCTAssertEqual(try rejected(declaration(setting: "hostAPI",
                                                to: ["minimum": "1", "maximumExclusive": "2.0"])),
                       .invalidHostAPIVersion(path: "hostAPI.minimum", value: "1"))
        XCTAssertEqual(try rejected(declaration(setting: "hostAPI",
                                                to: ["minimum": "1.0", "maximumExclusive": "2.0.0"])),
                       .invalidHostAPIVersion(path: "hostAPI.maximumExclusive", value: "2.0.0"))
    }

    func testInvertedHostAPIRangeIsRejected() throws {
        XCTAssertEqual(try rejected(declaration(setting: "hostAPI",
                                                to: ["minimum": "2.0", "maximumExclusive": "1.0"])),
                       .emptyHostAPIRange(minimum: "2.0", maximumExclusive: "1.0"))
    }

    /// Criterion 9: no intersection means the Source is not registered.
    func testHostAPIRangeWithNoIntersectionPreventsRegistration() throws {
        let declaration = self.declaration(setting: "hostAPI",
                                           to: ["minimum": "2.0", "maximumExclusive": "3.0"])
        let error = try rejected(declaration, hostAPI: .v1)
        guard case .incompatibleHostAPI(let declared, let supported) = error else {
            return XCTFail("expected .incompatibleHostAPI, got \(error)")
        }
        XCTAssertEqual(declared.minimum, HostAPIVersion(major: 2, minor: 0))
        XCTAssertEqual(declared.maximumExclusive, HostAPIVersion(major: 3, minor: 0))
        XCTAssertEqual(supported, [HostAPIVersion(major: 1, minor: 0),
                                   HostAPIVersion(major: 1, minor: 1),
                                   HostAPIVersion(major: 1, minor: 2)])
    }

    func testWildcardAssetOriginIsScopedAndShapeChecked() throws {
        var acceptedJSON = baseDeclaration()
        var network = try XCTUnwrap(acceptedJSON["network"] as? [String: Any])
        network["assetOrigins"] = ["https://*.mangadex.network"]
        acceptedJSON["network"] = network
        XCTAssertEqual(try accepted(acceptedJSON).network.assetOrigins,
                       ["https://*.mangadex.network"])

        for key in ["httpOrigins", "browserOrigins"] {
            var rejectedJSON = baseDeclaration()
            var mutated = try XCTUnwrap(rejectedJSON["network"] as? [String: Any])
            mutated[key] = ["https://*.mangadex.network"]
            rejectedJSON["network"] = mutated
            guard case .invalidOrigin = try rejected(rejectedJSON) else {
                return XCTFail("wildcard unexpectedly accepted in \(key)")
            }
        }

        for value in ["https://m*ngadex.network", "https://*.*.mangadex.network",
                      "https://*.network", "https://*.com", "https://*.github.io.",
                      "https://a..b", "http://*.mangadex.network"] {
            var rejectedJSON = baseDeclaration()
            var mutated = try XCTUnwrap(rejectedJSON["network"] as? [String: Any])
            mutated["assetOrigins"] = [value]
            rejectedJSON["network"] = mutated
            guard case .invalidOrigin = try rejected(rejectedJSON) else {
                return XCTFail("wildcard unexpectedly accepted: \(value)")
            }
        }

        var legacy = baseDeclaration()
        legacy["hostAPI"] = ["minimum": "1.0", "maximumExclusive": "1.2"]
        var legacyNetwork = try XCTUnwrap(legacy["network"] as? [String: Any])
        legacyNetwork["assetOrigins"] = ["https://*.mangadex.network"]
        legacy["network"] = legacyNetwork
        XCTAssertEqual(try rejected(legacy),
                       .featureRequiresHostAPIVersion(feature: "network.assetOrigins wildcard",
                                                      minimum: HostAPIVersion(major: 1, minor: 2),
                                                      selected: HostAPIVersion(major: 1, minor: 1)))
    }

    /// Criterion 9's "actionable": the message must name the declared range and what the
    /// host actually supports, so a reader can tell which side needs updating.
    func testIncompatibleHostAPIErrorNamesEveryVersionInvolved() throws {
        let declaration = self.declaration(setting: "hostAPI",
                                           to: ["minimum": "2.0", "maximumExclusive": "3.0"])
        let support = HostAPISupport(installedVersions: [HostAPIVersion(major: 1, minor: 0),
                                                         HostAPIVersion(major: 1, minor: 4)])
        let message = try rejected(declaration, hostAPI: support).message

        XCTAssertTrue(message.contains("2.0"), message)
        XCTAssertTrue(message.contains("3.0"), message)
        XCTAssertTrue(message.contains("1.0"), message)
        XCTAssertTrue(message.contains("1.4"), message)
        XCTAssertTrue(message.lowercased().contains("update"), message)
    }

    /// The one place manifest validation meets the operation-error taxonomy: registration
    /// refusal for a version mismatch carries S2's shared `incompatible_version` code
    /// rather than a code of its own.
    func testIncompatibleHostAPIUsesTheSharedErrorCode() throws {
        let declaration = self.declaration(setting: "hostAPI",
                                           to: ["minimum": "2.0", "maximumExclusive": "3.0"])
        let error = try rejected(declaration)
        XCTAssertEqual(error.hostAPICode, .incompatibleVersion)
        XCTAssertEqual(error.hostAPICode?.rawValue, "incompatible_version")
    }

    /// Every other rejection happens before there is an invocation to name, so it carries
    /// no code from that taxonomy rather than being forced into a misleading one.
    func testRejectionsOtherThanVersionMismatchCarryNoOperationErrorCode() throws {
        XCTAssertNil(try rejected(declaration(setting: "adult", to: nil)).hostAPICode)
        XCTAssertNil(try rejected(declaration(setting: "localId", to: "NOPE")).hostAPICode)
    }

    func testHighestVersionInTheIntersectionIsSelected() throws {
        let support = HostAPISupport(installedVersions: [HostAPIVersion(major: 1, minor: 0),
                                                         HostAPIVersion(major: 1, minor: 4),
                                                         HostAPIVersion(major: 2, minor: 0)])
        let declaration = try accepted(baseDeclaration(), hostAPI: support)
        XCTAssertEqual(declaration.selectedHostAPIVersion, HostAPIVersion(major: 1, minor: 4))
    }

    // MARK: - update immutability

    func testLocalIdCannotChangeAcrossAnUpdate() throws {
        let previous = try accepted(baseDeclaration())
        let renamedId = try accepted(declaration(setting: "localId", to: "example-madara-site-2"))

        XCTAssertEqual(SourceDeclarationValidator.validateUpdate(from: previous, to: renamedId),
                       .localIDChanged(from: "example-madara-site", to: "example-madara-site-2"))
    }

    func testQualifiedIdentityCannotChangeAcrossAnUpdate() throws {
        let previous = try accepted(baseDeclaration())
        let data = try JSONSerialization.data(withJSONObject: baseDeclaration())
        let elsewhere = try SourceDeclarationValidator
            .validate(json: data,
                      qualifiedId: QualifiedSourceID(rawValue: "repo-other:example-madara-site"),
                      hostAPI: .v1).get()

        XCTAssertEqual(SourceDeclarationValidator.validateUpdate(from: previous, to: elsewhere),
                       .qualifiedIdentityChanged)
    }

    /// Name, engine, configuration and capabilities are all free to change in an update.
    func testMutableFieldsMayChangeAcrossAnUpdate() throws {
        let previous = try accepted(baseDeclaration())
        var next = baseDeclaration()
        next["name"] = "Renamed"
        next["engine"] = "madara-v2"
        next["configuration"] = ["baseURL": "https://example.test/v2"]
        var capabilities = next["capabilities"] as? [String: Any] ?? [:]
        capabilities["tagBrowse"] = true
        next["capabilities"] = capabilities

        let updated = try accepted(next)
        XCTAssertNil(SourceDeclarationValidator.validateUpdate(from: previous, to: updated))
    }
}
