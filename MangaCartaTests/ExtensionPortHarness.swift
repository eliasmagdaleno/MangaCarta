//
//  ExtensionPortHarness.swift
//  MangaCartaTests
//
//  The offline site harness the S6 port tests run against.
//
//  Both sides of the equivalence proof — the compiled `WeebCentralSource` and the
//  configuration-backed Extension — load **the same captured HTML** into a real
//  `WKWebView` and run their own extraction script over the resulting DOM. That is the
//  only way the comparison means anything: a hand-written DOM stub would be testing the
//  stub, and a live fetch would make a merge-blocking test depend on WeebCentral being
//  up and unredesigned (`CLAUDE.md`'s flaky-live-network lesson).
//
//  Subresources are blocked by a content rule list, so no fixture reaches the network
//  and the DOM every test sees is exactly the server-rendered markup that was captured.
//
//  Fixtures are resolved from `#filePath`, the convention `RecommendationGoldenTests`
//  already uses here, so adding one needs no `project.pbxproj` edit.
//

import Foundation
import WebKit
@testable import MangaCarta

// MARK: - Fixture routing

/// One offline site: a directory of captured HTML plus the URL each file answers.
struct FixtureSite {
    let directory: String
    private var routes: [String: String] = [:]

    init(directory: String) {
        self.directory = directory
    }

    /// Registers `fixture` as the response for `url`. Query order is normalized, because
    /// the compiled source builds its query from an ordered array while the Extension
    /// builds it from a JSON object, whose key order Swift's `Dictionary` does not keep.
    mutating func route(_ url: String, to fixture: String) {
        routes[FixtureSite.canonical(url)] = fixture
    }

    func fixture(for url: URL) -> String? {
        routes[FixtureSite.canonical(url.absoluteString)]
    }

    func html(for url: URL) throws -> String {
        guard let name = fixture(for: url) else {
            throw FixtureSiteError.unroutedURL(FixtureSite.canonical(url.absoluteString))
        }
        return try String(contentsOf: FixtureSite.root
            .appendingPathComponent(directory)
            .appendingPathComponent(name), encoding: .utf8)
    }

    static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("__Fixtures__")
    }

    static func canonical(_ raw: String) -> String {
        guard var components = URLComponents(string: raw) else { return raw }
        components.fragment = nil
        let items = (components.queryItems ?? []).sorted {
            ($0.name, $0.value ?? "") < ($1.name, $1.value ?? "")
        }
        components.queryItems = items.isEmpty ? nil : items
        return components.string ?? raw
    }
}

enum FixtureSiteError: Error, CustomStringConvertible {
    case unroutedURL(String)
    case scriptFailed(String)
    case notAJSONValue

    var description: String {
        switch self {
        case .unroutedURL(let url): return "no fixture is routed for \(url)"
        case .scriptFailed(let reason): return "the extraction script failed: \(reason)"
        case .notAJSONValue: return "the extraction result is not a JSON value"
        }
    }
}

// MARK: - The DOM

/// Loads captured HTML into a real `WKWebView` and evaluates a script against it.
@MainActor
final class FixtureDOM {
    static let shared = FixtureDOM()

    private var ruleList: WKContentRuleList?
    private var webView: WKWebView?
    private var queue: Task<Any?, Error>?

    /// Blocks every subresource so a fixture can never reach the network, and so the DOM
    /// stays the server-rendered markup rather than whatever the site's own scripts would
    /// have rewritten it into.
    private static let blockEverything = """
    [{"trigger":{"url-filter":".*","resource-type":["image","style-sheet","font","media",
    "raw","script","svg-document","popup"]},
    "action":{"type":"block"}}]
    """.replacingOccurrences(of: "\n", with: "")

    /// One web view, one load at a time. A web view per extraction exhausts the
    /// simulator's WebKit content processes partway through a suite, which surfaces as an
    /// `extensionKit` "No such process found" failure rather than anything about the test.
    func evaluate(_ script: String, on html: String, baseURL: URL) async throws -> Any? {
        let previous = queue
        let task = Task { @MainActor [self] in
            _ = try? await previous?.value
            return try await perform(script, on: html, baseURL: baseURL)
        }
        queue = task
        return try await task.value
    }

    private func perform(_ script: String, on html: String, baseURL: URL) async throws -> Any? {
        let webView = try await reusableWebView()
        // Cleared before the load so a poll cannot read the previous document's flag.
        _ = try? await run("window.__fixtureReady = false", in: webView)
        webView.loadHTMLString(html, baseURL: baseURL)
        try await waitForDocument(in: webView)
        return try await run(script, in: webView)
    }

    private func reusableWebView() async throws -> WKWebView {
        if let webView { return webView }
        let configuration = WKWebViewConfiguration()
        // The page's own JavaScript is off: `evaluateJavaScript` and `WKUserScript` still
        // run, but inline handlers do not. Without this, blocking the images makes every
        // WeebCentral reader `<img onerror>` rewrite its own `src` to a local placeholder,
        // and the fixture would be measuring the harness rather than the site.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.userContentController.add(try await rules())
        configuration.userContentController.addUserScript(
            WKUserScript(source: "window.__fixtureReady = true;",
                         injectionTime: .atDocumentEnd,
                         forMainFrameOnly: true)
        )
        let created = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844),
                                configuration: configuration)
        webView = created
        return created
    }

    /// Loud on failure: a silently uncompiled rule list would let fixtures reach the
    /// network, which is the one thing this harness exists to prevent.
    private func rules() async throws -> WKContentRuleList {
        if let ruleList { return ruleList }
        guard let store = WKContentRuleListStore.default() else {
            throw FixtureSiteError.scriptFailed("no content rule list store")
        }
        let compiled = try await store.compileContentRuleList(
            forIdentifier: "mangacarta-fixture-block-all",
            encodedContentRuleList: Self.blockEverything
        )
        guard let compiled else {
            throw FixtureSiteError.scriptFailed("the fixture content blocker did not compile")
        }
        ruleList = compiled
        return compiled
    }

    private func waitForDocument(in webView: WKWebView) async throws {
        for _ in 0..<600 {
            let ready = try? await run("window.__fixtureReady === true", in: webView)
            if (ready as? NSNumber)?.boolValue == true { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw FixtureSiteError.scriptFailed("the fixture document never finished parsing")
    }

    private func run(_ script: String, in webView: WKWebView) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { value, error in
                if let error {
                    continuation.resume(throwing:
                        FixtureSiteError.scriptFailed(error.localizedDescription))
                } else {
                    continuation.resume(returning: value)
                }
            }
        }
    }
}

// MARK: - The two seams

/// `host.browser.extract` over captured HTML. Structured-clone semantics: the value is
/// returned as-is, never `JSON.stringify`-ed — the design's "Browser extraction" rule.
final class FixtureBrowser: ExtensionBrowserExtracting {
    private let site: FixtureSite
    private let lock = NSLock()
    private var visited: [URL] = []

    init(site: FixtureSite) {
        self.site = site
    }

    /// Every URL this Source's engine asked the browser to load, in order.
    var requestedURLs: [URL] { lock.withLock { visited } }

    func extract(_ request: HostBrowserRequest) async throws -> HostBrowserResult {
        lock.withLock { visited.append(request.url) }
        let html = try site.html(for: request.url)
        let raw = try await FixtureDOM.shared.evaluate(request.script,
                                                       on: html,
                                                       baseURL: request.url)
        guard let value = JSONValue(converting: raw ?? NSNull()) else {
            throw HostCapabilityError(code: .script, message: "extraction returned a non-JSON value")
        }
        return HostBrowserResult(value: value, finalURL: request.url, warnings: [])
    }
}

/// The compiled `WeebCentralSource`'s seam, over the very same fixtures. Its scripts do
/// end in `JSON.stringify(...)`, which is the convention the Host API deliberately drops.
final class FixtureWebViewExtractor: WebViewExtracting {
    private let site: FixtureSite
    private let lock = NSLock()
    private var visited: [URL] = []

    init(site: FixtureSite) {
        self.site = site
    }

    var requestedURLs: [URL] { lock.withLock { visited } }

    func extract<T: Decodable>(from url: URL, script: String, as type: T.Type) async throws -> T {
        lock.withLock { visited.append(url) }
        let html = try site.html(for: url)
        let raw = try await FixtureDOM.shared.evaluate(script, on: html, baseURL: url)
        guard let json = raw as? String, let data = json.data(using: .utf8) else {
            throw FixtureSiteError.notAJSONValue
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - The three configured Sources

/// One configured Source, assembled the way the host will assemble it: a validated
/// declaration, the shared engine bundle, and a `host.browser` wired to captured HTML.
struct PortedSource {
    let declaration: SourceDeclaration
    let runtime: ExtensionRuntime
    let browser: FixtureBrowser
    let validator: ExtensionDomainValidator

    func listings(_ operation: SourceOperation,
                  request: [String: Any]) async throws -> ExtensionValidatedPage<ExtensionListing> {
        try validator.validateListingPage(try await runtime.invoke(operation, request: request))
    }
}

enum PortFixtures {

    static let weebSeriesID = "01KQJGKCAB7Q2GJ5T27N2WVNP6"
    static let weebChapterID = "01M28WY2S88MW6WRSNYC19R63V"
    static let weebCentralJSON = HTMLSelectorThemeEngine.weebCentralJSON

    // MARK: Declarations

    static func declaration(_ json: String, qualifiedId: String) throws -> SourceDeclaration {
        let result = SourceDeclarationValidator.validate(
            json: Data(json.utf8),
            qualifiedId: QualifiedSourceID(rawValue: qualifiedId)
        )
        switch result {
        case .success(let declaration): return declaration
        case .failure(let error): throw FixtureDeclarationError.rejected(error.message)
        }
    }

    static func allDeclarations() throws -> [SourceDeclaration] {
        [try declaration(weebCentralJSON, qualifiedId: "repo-test:weebcentral"),
         try declaration(pagedInkJSON, qualifiedId: "repo-test:paged-ink"),
         try declaration(slugComicsJSON, qualifiedId: "repo-test:slug-comics")]
    }

    // MARK: Assembled Sources

    static func source(_ json: String,
                       qualifiedId: String,
                       site: FixtureSite) throws -> PortedSource {
        let declaration = try declaration(json, qualifiedId: qualifiedId)
        let browser = FixtureBrowser(site: site)
        let runtime = ExtensionRuntime(
            bundleScript: HTMLSelectorThemeEngine.bundleScript,
            declaration: declaration,
            capabilities: [HostBrowserJSCapability(extractor: browser)]
        )
        return PortedSource(declaration: declaration,
                            runtime: runtime,
                            browser: browser,
                            validator: ExtensionDomainValidator(
                                assetOrigins: declaration.network.assetOrigins))
    }

    static func weebCentral() throws -> PortedSource {
        try source(weebCentralJSON, qualifiedId: "repo-test:weebcentral", site: weebCentralSite)
    }

    static func pagedInk() throws -> PortedSource {
        try source(pagedInkJSON, qualifiedId: "repo-test:paged-ink", site: pagedInkSite)
    }

    static func slugComics() throws -> PortedSource {
        try source(slugComicsJSON, qualifiedId: "repo-test:slug-comics", site: slugComicsSite)
    }

    /// The compiled Source under test, reading the same fixtures through its own seam.
    static func compiledWeebCentral() -> (source: WeebCentralSource, webView: FixtureWebViewExtractor) {
        let extractor = FixtureWebViewExtractor(site: weebCentralSite)
        return (WeebCentralSource(context: SourceContext(webView: extractor)), extractor)
    }

    // MARK: Sites

    static var weebCentralSite: FixtureSite {
        var site = FixtureSite(directory: "weebcentral")
        let base = "https://weebcentral.com"
        site.route("\(base)/search/data?sort=Popularity&display_mode=Full%20Display"
                   + "&limit=8&offset=0", to: "popular.html")
        site.route("\(base)/search/data?sort=Recently%20Added&display_mode=Full%20Display"
                   + "&limit=8&offset=0", to: "new-titles.html")
        site.route("\(base)/search/data?sort=Best%20Match&display_mode=Full%20Display"
                   + "&limit=8&offset=0&text=berserk", to: "search.html")
        site.route("\(base)/latest-updates/1", to: "latest-updates.html")
        site.route("\(base)/series/\(weebSeriesID)", to: "detail.html")
        site.route("\(base)/series/\(weebSeriesID)/full-chapter-list", to: "chapters.html")
        site.route("\(base)/chapters/\(weebChapterID)/images?reading_style=long_strip",
                   to: "pages.html")
        return site
    }

    static var pagedInkSite: FixtureSite {
        var site = FixtureSite(directory: "pagedink")
        site.route("https://paged-ink.test/browse/popular/1", to: "popular.html")
        site.route("https://paged-ink.test/title/pi-001", to: "detail.html")
        site.route("https://paged-ink.test/title/pi-001/chapters", to: "chapters.html")
        site.route("https://paged-ink.test/read/pi-001-c3", to: "pages.html")
        return site
    }

    static var slugComicsSite: FixtureSite {
        var site = FixtureSite(directory: "slugcomics")
        site.route("https://slug-comics.test/catalogue/trending?start=0", to: "popular.html")
        site.route("https://slug-comics.test/manga/sc-77", to: "detail.html")
        site.route("https://slug-comics.test/manga/sc-77/list", to: "chapters.html")
        site.route("https://slug-comics.test/reader/sc-77-12", to: "pages.html")
        return site
    }

    // MARK: Two more configurations of the same engine

    /// Page-number pagination, a different id segment, different selectors, a different
    /// adult label, and a client-side trim its server does not perform.
    static let pagedInkJSON = """
    {
      "localId": "paged-ink",
      "name": "Paged Ink",
      "engine": "\(HTMLSelectorThemeEngine.engineName)",
      "adult": "none",
      "capabilities": {
        "search": true, "popular": true, "detail": true,
        "chapters": true, "pages": true, "webURL": true
      },
      "languages": { "mode": "fixed", "values": ["en"] },
      "network": {
        "httpOrigins": [],
        "browserOrigins": ["https://paged-ink.test"],
        "assetOrigins": ["https://cdn.paged-ink.test", "https://paged-ink.test"]
      },
      "hostAPI": { "minimum": "1.0", "maximumExclusive": "2.0" },
      "configuration": {
        "baseURL": "https://paged-ink.test",
        "operations": {
          "popular": { "path": "/browse/popular/{page}" },
          "search": { "path": "/find", "query": { "q": "{query}", "p": "{page}" } },
          "detail": { "path": "/title/{listingId}" },
          "chapters": { "path": "/title/{listingId}/chapters" },
          "pages": { "path": "/read/{chapterId}" },
          "webURL": { "path": "/title/{listingId}" }
        },
        "pagination": { "listings": "page", "firstPage": 1,
                        "clientLimit": ["popular", "search"] },
        "selectors": {
          "listing": { "item": "li.card", "link": "a.card-link",
                       "title": ["h3.card-title"], "image": "img.thumb",
                       "idSegment": "title" },
          "detail": { "description": "p.synopsis", "authorLabel": "Written by",
                      "authorLink": "span a", "tagLabel": "Genres", "tagLink": "a",
                      "adultLabel": "Mature" },
          "chapter": { "item": "a.chapter-row", "title": ["em.label"],
                       "date": "time.when", "idSegment": "read" },
          "page": { "image": ".strip img.panel" }
        },
        "chapterNumber": { "pattern": "\\\\d+(\\\\.\\\\d+)?" },
        "contentRating": { "adult": "erotica", "default": "safe" }
      }
    }
    """

    /// Offset pagination again, but with a different query name, covers that live only in
    /// `data-src`, a different adult rating mapping, and a table-shaped chapter list.
    static let slugComicsJSON = """
    {
      "localId": "slug-comics",
      "name": "Slug Comics",
      "engine": "\(HTMLSelectorThemeEngine.engineName)",
      "adult": "mixed",
      "capabilities": {
        "search": true, "popular": true, "detail": true,
        "chapters": true, "pages": true, "webURL": true
      },
      "languages": { "mode": "fixed", "values": ["en"] },
      "network": {
        "httpOrigins": [],
        "browserOrigins": ["https://slug-comics.test"],
        "assetOrigins": ["https://images.slug-comics.test"]
      },
      "hostAPI": { "minimum": "1.0", "maximumExclusive": "2.0" },
      "configuration": {
        "baseURL": "https://slug-comics.test",
        "operations": {
          "popular": { "path": "/catalogue/trending", "query": { "start": "{offset}" } },
          "search": { "path": "/catalogue/search", "query": { "start": "{offset}" } },
          "detail": { "path": "/manga/{listingId}" },
          "chapters": { "path": "/manga/{listingId}/list" },
          "pages": { "path": "/reader/{chapterId}" },
          "webURL": { "path": "/manga/{listingId}" }
        },
        "pagination": { "listings": "offset", "clientLimit": ["popular", "search"] },
        "selectors": {
          "listing": { "item": "div.grid-entry", "link": "a.entry",
                       "title": ["span.entry-name"], "image": "img",
                       "idSegment": "manga" },
          "detail": { "description": "div.blurb", "authorLabel": "Author",
                      "authorLink": "span a", "tagLabel": "Tags", "tagLink": "a",
                      "adultLabel": "Adult Content" },
          "chapter": { "item": "a.ch", "title": ["b.name"], "date": "time[datetime]",
                       "idSegment": "reader" },
          "page": { "image": "main.viewer img.page-image" }
        },
        "chapterNumber": { "pattern": "\\\\d+(\\\\.\\\\d+)?" },
        "contentRating": { "adult": "pornographic", "default": "suggestive" }
      }
    }
    """
}

enum FixtureDeclarationError: Error, CustomStringConvertible {
    case rejected(String)

    var description: String {
        switch self {
        case .rejected(let message): return "the declaration was rejected: \(message)"
        }
    }
}
