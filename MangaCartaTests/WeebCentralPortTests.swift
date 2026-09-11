//
//  WeebCentralPortTests.swift
//  MangaCartaTests
//
//  Acceptance criteria 1 and 12 of the Host API design's "Acceptance criteria for the
//  later runtime".
//
//  * **Criterion 1** — "one theme engine serves at least three differently configured
//    Sources without code duplication". Three declarations select `htmlSelectorTheme`
//    and differ only in `configuration`; each validates, registers and invokes on its
//    own, and each produces results that follow its own configuration.
//  * **Criterion 12** — "the compiled WeebCentral Source can be replaced by a
//    configuration-backed Extension with equivalent browse/detail/chapter/page
//    behavior, modulo intentional validation improvements". Both run over identical
//    captured HTML; the improvements are named and asserted rather than excused.
//

import XCTest
import WebKit
@testable import MangaCarta

final class WeebCentralPortTests: XCTestCase {

    // MARK: - Criterion 1: one engine, three configurations

    /// Criterion 1, clause "three differently configured Sources": each declaration
    /// validates on its own through `SourceDeclarationValidator`, with its own identity.
    func testThreeConfiguredSourcesValidateIndependently() throws {
        let declarations = try PortFixtures.allDeclarations()

        XCTAssertEqual(declarations.map(\.localId), ["weebcentral", "paged-ink", "slug-comics"])
        XCTAssertEqual(Set(declarations.map(\.qualifiedId.rawValue)).count, 3)

        // Different configuration, not different code: base URLs and selectors differ.
        let baseURLs = declarations.map { $0.configuration.objectValue?["baseURL"]?.stringValue }
        XCTAssertEqual(baseURLs, ["https://weebcentral.com",
                                  "https://paged-ink.test",
                                  "https://slug-comics.test"])
        XCTAssertEqual(Set(baseURLs.compactMap { $0 }).count, 3)
    }

    /// Criterion 1, clause "one theme engine ... without code duplication": all three
    /// name the same engine, and the bundle registers exactly one.
    func testAllThreeSourcesSelectTheSameSingleEngine() throws {
        let declarations = try PortFixtures.allDeclarations()
        XCTAssertEqual(Set(declarations.map(\.engine)),
                       [HTMLSelectorThemeEngine.engineName])

        let bundle = HTMLSelectorThemeEngine.bundleScript
        let registrations = bundle.components(separatedBy: "registerEngine(").count - 1
        XCTAssertEqual(registrations, 1, "the bundle must define one engine, not one per site")

        // No site is hardcoded in the engine: every WeebCentral-specific string lives in
        // the declaration. This is the mechanical form of "without code duplication".
        for needle in ["weebcentral.com", "/search/data", "whitespace-pre-wrap",
                       "aspect-square", "paged-ink", "slug-comics"] {
            XCTAssertFalse(bundle.contains(needle),
                           "engine code must not mention the site-specific '\(needle)'")
        }
    }

    /// Criterion 1, clause "serves ... Sources": each configuration drives the engine to
    /// its own URLs and its own DOM, producing results that belong to that site alone.
    func testEachConfiguredSourceProducesItsOwnResults() async throws {
        let weeb = try PortFixtures.weebCentral()
        let paged = try PortFixtures.pagedInk()
        let slug = try PortFixtures.slugComics()

        let weebItems = try await weeb.listings(.popular, request: ["limit": 8])
        let pagedItems = try await paged.listings(.popular, request: ["limit": 8])
        let slugItems = try await slug.listings(.popular, request: ["limit": 8])

        XCTAssertEqual(weeb.browser.requestedURLs.map(\.host), ["weebcentral.com"])
        XCTAssertEqual(paged.browser.requestedURLs.map(\.absoluteString),
                       ["https://paged-ink.test/browse/popular/1"])
        XCTAssertEqual(slug.browser.requestedURLs.map(\.absoluteString),
                       ["https://slug-comics.test/catalogue/trending?start=0"])

        XCTAssertEqual(pagedItems.items.map(\.id), ["pi-001", "pi-002", "pi-003", "pi-004"])
        XCTAssertEqual(pagedItems.items.map(\.title),
                       ["Ashes of the Kiln", "Bellringer's Holiday", "Cinders", "Dross"])
        XCTAssertEqual(slugItems.items.map(\.id), ["sc-77", "sc-78"])
        XCTAssertEqual(slugItems.items.map(\.title), ["Quiet Tide", "Rust and Rain"])

        XCTAssertFalse(weebItems.items.isEmpty)
        XCTAssertTrue(Set(weebItems.items.map(\.id))
            .isDisjoint(with: Set(pagedItems.items.map(\.id))))

        // Pagination style is configuration too: WeebCentral's listings use an offset
        // cursor, Paged Ink's a page number.
        XCTAssertEqual(pagedItems.exhausted, true)
        XCTAssertEqual(slugItems.exhausted, true)
    }

    /// Criterion 1, clause "without ... shared state": the runtime builds a fresh
    /// `JSContext` per invocation, so nothing one invocation leaves on `globalThis`
    /// survives into the next — asserted, not assumed.
    func testInvocationsShareNoMutableJavaScriptState() async throws {
        let probe = """
        registerEngine("\(HTMLSelectorThemeEngine.engineName)", {
          invoke: function () {
            var seen = globalThis.__leaked === true;
            globalThis.__leaked = true;
            return { ok: true, value: { items: [], exhausted: true, sawPreviousWrite: seen } };
          }
        });
        """
        let declaration = try PortFixtures.declaration(PortFixtures.weebCentralJSON,
                                                       qualifiedId: "repo-test:weebcentral")
        let runtime = ExtensionRuntime(bundleScript: probe, declaration: declaration)

        for attempt in 1...2 {
            let value = try await runtime.invoke(.popular, request: [:]) as? [String: Any]
            XCTAssertEqual(value?["sawPreviousWrite"] as? Bool, false,
                           "invocation \(attempt) saw a previous invocation's globalThis write")
        }
    }

    // MARK: - Criterion 12: browse

    /// Criterion 12, clause "browse": the three listing feeds, field for field.
    func testPortedBrowseMatchesCompiledSource() async throws {
        let ported = try PortFixtures.weebCentral()
        let compiled = PortFixtures.compiledWeebCentral()

        let cases: [(SourceOperation, [String: Any], [Manga])] = [
            (.popular, ["limit": 8], try await compiled.source.popular(limit: 8, offset: 0)),
            (.newTitles, ["limit": 8], try await compiled.source.newTitles(limit: 8, offset: 0)),
            (.search, ["limit": 8, "query": "berserk"],
             try await compiled.source.search(title: "berserk", limit: 8, offset: 0))
        ]

        for (operation, request, expected) in cases {
            let page = try await ported.listings(operation, request: request)
            let actual = page.items.map { $0.toManga(sourceID: WeebCentralSource.sourceID) }
            XCTAssertFalse(expected.isEmpty, "\(operation.rawValue) fixture produced nothing")
            XCTAssertEqual(actual, expected, "\(operation.rawValue) differs from the compiled source")
        }
    }

    /// Criterion 12, clause "browse": the latest-updates feed, including the page-number
    /// pagination and the client-side trim the compiled source performs.
    func testPortedLatestUpdatesMatchCompiledSource() async throws {
        let ported = try PortFixtures.weebCentral()
        let compiled = PortFixtures.compiledWeebCentral()

        let expected = try await compiled.source.latestUpdates(limitTitles: 8,
                                                               language: "en",
                                                               offset: 0)
        let raw = try await ported.runtime.invoke(.latestUpdates, request: ["limit": 8])
        let page = try ported.validator.validateUpdatePage(raw)
        let actual = page.items.map { $0.toMangaUpdate(sourceID: WeebCentralSource.sourceID) }

        XCTAssertFalse(expected.isEmpty)
        XCTAssertEqual(actual.map(\.chapterId), expected.map(\.chapterId))
        XCTAssertEqual(actual.map(\.manga), expected.map(\.manga))
        XCTAssertEqual(ported.browser.requestedURLs.map(\.absoluteString),
                       ["https://weebcentral.com/latest-updates/1"])
    }

    // MARK: - Criterion 12: detail

    /// Criterion 12, clause "detail". The one difference is deliberate and asserted
    /// below in `testPortedDetailOmitsFabricatedTagIdentifiers`.
    func testPortedDetailMatchesCompiledSource() async throws {
        let ported = try PortFixtures.weebCentral()
        let compiled = PortFixtures.compiledWeebCentral()

        let expected = try await compiled.source.mangaDetail(id: PortFixtures.weebSeriesID)
        let raw = try await ported.runtime.invoke(.detail,
                                                  request: ["listingId": PortFixtures.weebSeriesID])
        let actual = try ported.validator.validateDetail(raw).value.toMangaDetail()

        XCTAssertFalse(expected.description.isEmpty)
        XCTAssertEqual(actual.description, expected.description)
        XCTAssertEqual(actual.authors, expected.authors)
        XCTAssertEqual(actual.contentRating, expected.contentRating)
        XCTAssertEqual(actual.tags.map(\.name), expected.tags.map(\.name))
        XCTAssertFalse(actual.tags.isEmpty)
    }

    /// Criterion 12's "modulo intentional validation improvements", stated as a test so
    /// the difference cannot drift unnoticed: the compiled source fabricates `""` for a
    /// tag id and group it does not have, which the design's Detail schema makes
    /// optional. The port omits them instead.
    func testPortedDetailOmitsFabricatedTagIdentifiers() async throws {
        let ported = try PortFixtures.weebCentral()
        let compiled = PortFixtures.compiledWeebCentral()

        let expected = try await compiled.source.mangaDetail(id: PortFixtures.weebSeriesID)
        let raw = try await ported.runtime.invoke(.detail,
                                                  request: ["listingId": PortFixtures.weebSeriesID])
        let actual = try ported.validator.validateDetail(raw).value.toMangaDetail()

        XCTAssertEqual(expected.tags.map(\.id), Array(repeating: "", count: expected.tags.count))
        XCTAssertEqual(actual.tags.compactMap(\.id), [], "the port must not invent tag ids")
        XCTAssertEqual(actual.tags.compactMap(\.group), [])
    }

    // MARK: - Criterion 12: chapters

    /// Criterion 12, clause "chapter": same chapters, same order, same dates.
    func testPortedChaptersMatchCompiledSource() async throws {
        let ported = try PortFixtures.weebCentral()
        let compiled = PortFixtures.compiledWeebCentral()

        let expected = try await compiled.source.chapters(mangaId: PortFixtures.weebSeriesID)
        let raw = try await ported.runtime.invoke(.chapters,
                                                  request: ["listingId": PortFixtures.weebSeriesID])
        let actual = try ported.validator.validateChapters(raw).value.map { $0.toChapter() }

        XCTAssertFalse(expected.isEmpty)
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(ported.browser.requestedURLs.map(\.absoluteString),
                       ["https://weebcentral.com/series/\(PortFixtures.weebSeriesID)/full-chapter-list"])
    }

    /// Criterion 12, clause "chapter", for the one piece of domain logic in the compiled
    /// source that has no wire type: the display number is the last numeric token, and a
    /// title carrying none shows `?`.
    func testChapterNumberDisplayValuesMatchCompiledSource() async throws {
        let ported = try PortFixtures.pagedInk()
        let raw = try await ported.runtime.invoke(.chapters, request: ["listingId": "pi-001"])
        let chapters = try ported.validator.validateChapters(raw).value.map { $0.toChapter() }

        XCTAssertEqual(chapters.map(\.number), ["3", "2.5", "11.5", "?"])
        XCTAssertEqual(chapters.map(\.number),
                       chapters.map { WeebCentralSource.chapterNumber(fromTitle: $0.title ?? "") })
    }

    // MARK: - Criterion 12: pages

    /// Criterion 12, clause "page": the same image URLs in the same order.
    func testPortedPagesMatchCompiledSource() async throws {
        let ported = try PortFixtures.weebCentral()
        let compiled = PortFixtures.compiledWeebCentral()

        let expected = try await compiled.source.pageURLs(chapterId: PortFixtures.weebChapterID,
                                                          preferDataSaver: false)
        let raw = try await ported.runtime.invoke(.pages,
                                                  request: ["chapterId": PortFixtures.weebChapterID,
                                                            "quality": "original"])
        let actual = try ported.validator.validatePages(raw).value.map(\.url)

        XCTAssertFalse(expected.isEmpty)
        XCTAssertEqual(actual, expected)
    }

    /// Criterion 12, clause "browse"/"page" boundary: `webURL`.
    func testPortedWebURLMatchesCompiledSource() async throws {
        let ported = try PortFixtures.weebCentral()
        let compiled = PortFixtures.compiledWeebCentral()

        let expected = compiled.source.webURL(forManga: PortFixtures.weebSeriesID)
        let raw = try await ported.runtime.invoke(.webURL,
                                                  request: ["listingId": PortFixtures.weebSeriesID])
        let actual = (raw as? [String: Any])?["url"] as? String

        XCTAssertEqual(actual, expected?.absoluteString)
    }

    // MARK: - The other intentional improvement

    /// ADR-0024, and criterion 12's "modulo intentional validation improvements": a
    /// policy-invalid cover costs the cover, not the item — and it is now *visible* as a
    /// `policy_invalid_url` warning, where the compiled source reported nothing at all.
    func testPolicyInvalidCoverDropsTheCoverNotTheItem() async throws {
        let ported = try PortFixtures.pagedInk()
        let page = try await ported.listings(.popular, request: ["limit": 8])

        XCTAssertEqual(page.items.map(\.id), ["pi-001", "pi-002", "pi-003", "pi-004"])
        XCTAssertNil(page.items.last?.coverURL, "an http:// cover is not a usable asset URL")
        XCTAssertEqual(page.warnings.map(\.code), [.policyInvalidURL])
        XCTAssertEqual(page.warnings.first?.itemIndex, 3)

        // The relative cover on item three still resolves against the page it came from.
        XCTAssertEqual(page.items[2].coverURL?.absoluteString,
                       "https://paged-ink.test/browse/covers/pi-003.jpg")
    }
}
