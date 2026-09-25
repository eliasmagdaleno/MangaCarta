# MangaDex JSON-API Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship MangaDex as an installable extension engine (`mangadexApi` + a `mangadex` Source
declaration) that reproduces the compiled `MangaDexAPI` behaviour through the Host API. This is
slice 5 of the no-built-in-Sources plan.

**Architecture:** The engine is one JavaScript bundle run by `ExtensionRuntime`. It talks to
`api.mangadex.org` only through `context.host.http.request`, and maps MangaDex JSON onto the Host API
wire schemas (Listing, Update, Detail, Chapter, Page). It is developed and tested in this repo against
captured MangaDex JSON: `ExtensionSource` runs over a real `HostHTTPClient` whose transport serves
fixtures. Then it is published verbatim to `proxy-link/mangacarta-sources`. Nothing in the app's Swift
code changes. The compiled `MangaDexSource` stays registered until a later slice removes it.

**Tech Stack:** ES2017 JavaScript (JavaScriptCore; no modules, no timers), Swift 6.0-compatible XCTest,
`xcodebuild`, `curl` + `jq` for fixture capture.

**Spec:**
- `docs/adr/0003-extension-substrate.md`, Amendment 6 (why: no built-in Sources)
- `docs/superpowers/specs/2026-09-02-host-api-design.md` (the contract: §2 schemas, §3 entry points, §4.1 HTTP, §6 errors, Amendments 5–6)
- `docs/superpowers/specs/2026-09-11-repository-format-design.md` §2 (index/bundle format), §5 (identity)
- PR #221's research note `docs/research/2026-09-22-mangadex-engine.md` (on branch of #221; AUP obligations, behaviour to replicate)

## Global Constraints

- Declaration `hostAPI` is `{"minimum": "1.2", "maximumExclusive": "2.0"}`. The engine needs 1.2 for `groups` and the `*.mangadex.network` asset wildcard.
- Engine name `mangadexApi`; Source `localId` `mangadex`; display name `MangaDex`.
- `network.httpOrigins` = `["https://api.mangadex.org"]`; `browserOrigins` = `[]`; `assetOrigins` = `["https://uploads.mangadex.org", "https://*.mangadex.network"]`.
- The engine must not set `User-Agent`, `Cookie` or `Authorization` headers (the host rejects them). The host's default UA is accepted as honest (decision 2026-09-25: no UA pin in this slice).
- `/manga` and `/chapter` `limit` ≤ 100; `offset + limit` ≤ 10000 (MangaDex API limitation).
- Every `/manga` query includes `includes[]=cover_art`; covers are `https://uploads.mangadex.org/covers/{mangaId}/{fileName}.512.jpg` (CLAUDE.md convention).
- Scanlation groups are credited on every chapter (`includes[]=scanlation_group` → `groups`), per MangaDex AUP.
- `pages` honours `request.quality`: `dataSaver` → `data-saver`/`chapter.dataSaver`, `original` → `data`/`chapter.data`.
- `ExtensionDetail` does **not** gain `externalIds` in this slice (decision 2026-09-25).
- No site name in any App Store metadata; nothing in this slice touches the app's user-facing copy.
- The app must not link to or name the engines repository (ADR-0003 A6 decision 2).
- The engines repo is pushed only via the `github-proxy-link` SSH alias, never with the owner's identity (memory: proxy-link engines repo).
- Swift must compile on CI's Swift 6.0: no isolated conformances, `nonisolated(nonsending)`, `@concurrent`, `Task.immediate`.
- Every `xcodebuild` targets `platform=iOS Simulator,name=iPhone 17 Pro`, parallel testing left on.

## Review Focus

1. **At-home `baseUrl` outside the declared asset origins** (e.g. a new CDN host). Expected: the whole `pages` result is rejected with a readable error, never a partial chapter. Pinned in Task 5.
2. **A manga with more than 100 English chapters.** Expected: every chapter comes back, in ascending order, with duplicates by number collapsed. Pinned in Task 4 with a two-page fixture.
3. **HTTP 429 from MangaDex.** Expected: `rate_limited` reaches the app (not a generic script error), carrying `Retry-After`. Pinned in Task 2.
4. **A title with no English title, or a `links.mal` that is a slug, not a number.** Expected: the first available title is used, and `malId` is `nil` with the Listing still shown. Pinned in Task 2.
5. **Latest Updates where several chapters belong to one manga, and `/manga?ids[]` returns titles in a different order than requested.** Expected: one update per manga, in newest-chapter order. Pinned in Task 3.

---

## File Structure

In this repo (worktree `../Manga-Reader-mangadex-engine`, branch `feat/mangadex-engine`):

| Path | Responsibility |
|---|---|
| `MangaCartaTests/__Fixtures__/mangadex/engine.js` | The engine. Byte-identical to the published copy. |
| `MangaCartaTests/__Fixtures__/mangadex/index.json` | Format-1 repository index holding the MangaDex declaration and the engine's SHA-256. Byte-identical to the published copy except the `script` URL. |
| `MangaCartaTests/__Fixtures__/mangadex/api/*.json` | Captured and hand-trimmed MangaDex responses. |
| `scripts/capture-mangadex-fixtures.sh` | Re-captures the live fixtures (manual, never in CI). |
| `MangaCartaTests/MangaDexEngineTests.swift` | Runs the engine through `ExtensionSource` over a fixture-backed `HostHTTPClient`. **Not a synchronized group**: add with `xcp`. |

In `~/mangacarta-sources` (remote `proxy-link/mangacarta-sources`):

| Path | Responsibility |
|---|---|
| `mangadex/engine.js` | Published engine (copy of the fixture). |
| `index.json` | Published format-1 index; `script` points at the raw GitHub URL of `mangadex/engine.js`. |

Fixtures are resolved via `#filePath` (`FixtureSite.root`), so adding fixture files needs no `project.pbxproj` edit.

---

### Task 1: Declaration, fixture host, and a declaration that validates

**Files:**
- Create: `MangaCartaTests/__Fixtures__/mangadex/index.json`
- Create: `MangaCartaTests/__Fixtures__/mangadex/engine.js` (skeleton)
- Create: `MangaCartaTests/MangaDexEngineTests.swift`

**Interfaces:**
- Produces: `MangaDexFixtures.declarationJSON: String`, `MangaDexFixtures.script: String`, `MangaDexFixtures.directory: URL`; `MangaDexFixtureTransport` (actor: `route(_ url: String, to file: String)`, `route(_ url: String, status: Int, headers: [String: String], file: String?)`, `requestedURLs() -> [String]`); `MangaDexFixtureHost: ExtensionSourceHosting`; helper `makeSource() throws -> ExtensionSource` in the test class.

- [ ] **Step 1: Write `index.json`**

```json
{
  "format": 1,
  "name": "MangaCarta Sources",
  "bundles": [
    {
      "id": "mangadex-api",
      "version": 1,
      "script": "https://raw.githubusercontent.com/proxy-link/mangacarta-sources/main/mangadex/engine.js",
      "scriptSHA256": "0000000000000000000000000000000000000000000000000000000000000000",
      "sources": [
        {
          "localId": "mangadex",
          "name": "MangaDex",
          "engine": "mangadexApi",
          "adult": "mixed",
          "externalIds": ["mal"],
          "capabilities": {
            "search": true,
            "popular": true,
            "newTitles": true,
            "latestUpdates": true,
            "tagBrowse": true,
            "detail": true,
            "chapters": true,
            "pages": true,
            "webURL": true,
            "listing": true
          },
          "languages": { "mode": "fixed", "values": ["en"] },
          "network": {
            "httpOrigins": ["https://api.mangadex.org"],
            "browserOrigins": [],
            "assetOrigins": ["https://uploads.mangadex.org", "https://*.mangadex.network"]
          },
          "presentation": {
            "feeds": {
              "popular": { "eyebrow": "Top rated" },
              "latestUpdates": { "eyebrow": "New chapters" },
              "newTitles": { "eyebrow": "Just added" }
            }
          },
          "hostAPI": { "minimum": "1.2", "maximumExclusive": "2.0" },
          "configuration": {
            "apiBaseURL": "https://api.mangadex.org",
            "coverBaseURL": "https://uploads.mangadex.org",
            "siteBaseURL": "https://mangadex.org"
          }
        }
      ]
    }
  ]
}
```

`adult: "mixed"`: MangaDex's default content filter (which the compiled Source relied on) returns `erotica`, so the Source is not `none`. `scriptSHA256` is fixed in Task 6.

- [ ] **Step 2: Write the engine skeleton**

```js
(function () {
  "use strict";

  function fail(code, message, retryAfterSeconds) {
    var error = { code: code, message: message };
    if (typeof retryAfterSeconds === "number") { error.retryAfterSeconds = retryAfterSeconds; }
    return { ok: false, error: error };
  }

  async function invoke(operation, request, context) {
    return fail("unsupported", operation + " is not implemented by this engine");
  }

  registerEngine("mangadexApi", { invoke: invoke });
})();
```

- [ ] **Step 3: Write the test scaffolding and the first test**

```swift
//
//  MangaDexEngineTests.swift
//  MangaCartaTests
//
//  The MangaDex extension engine (no-built-in-Sources slice 5), run exactly as an
//  installed Source runs: `ExtensionSource` → `ExtensionRuntime` → `host.http` →
//  `HostHTTPClient`. Only the transport is fake, and it serves captured MangaDex JSON,
//  so URL policy, redirects, rate limiting and result validation are all the real ones.
//
//  The engine and index under `__Fixtures__/mangadex/` are the copies published to the
//  engines repository; `testIndexPinsThisEngine` keeps the two from drifting.
//

import CryptoKit
import XCTest
@testable import MangaCarta

enum MangaDexFixtures {
    static var directory: URL { FixtureSite.root.appendingPathComponent("mangadex") }

    static let script: String = {
        let url = directory.appendingPathComponent("engine.js")
        guard let data = try? Data(contentsOf: url) else { preconditionFailure("missing \(url.path)") }
        return String(decoding: data, as: UTF8.self)
    }()

    static let index: [String: Any] = {
        let url = directory.appendingPathComponent("index.json")
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            preconditionFailure("missing or malformed \(url.path)")
        }
        return root
    }()

    static var bundle: [String: Any] {
        ((index["bundles"] as? [[String: Any]])?.first)!
    }

    static let declarationJSON: String = {
        let source = ((bundle["sources"] as? [[String: Any]])?.first)!
        let data = try! JSONSerialization.data(withJSONObject: source)
        return String(decoding: data, as: UTF8.self)
    }()

    static func body(_ file: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent("api").appendingPathComponent(file))
    }
}

/// Serves captured MangaDex JSON by canonical URL (query order normalized). An unrouted
/// URL is a test bug, so it answers 599 with the URL in the body rather than guessing.
actor MangaDexFixtureTransport: HostHTTPTransport {
    private struct Route { let status: Int; let headers: [String: String]; let file: String? }
    private var routes: [String: Route] = [:]
    private var urls: [String] = []

    func route(_ url: String, to file: String) {
        route(url, status: 200, headers: ["Content-Type": "application/json"], file: file)
    }

    func route(_ url: String, status: Int, headers: [String: String], file: String?) {
        routes[FixtureSite.canonical(url)] = Route(status: status, headers: headers, file: file)
    }

    func requestedURLs() -> [String] { urls }

    func send(_ request: URLRequest) async throws -> HostHTTPTransportResponse {
        let url = request.url!
        let key = FixtureSite.canonical(url.absoluteString)
        urls.append(key)
        guard let route = routes[key] else {
            return HostHTTPTransportResponse(statusCode: 599, url: url, headers: [:],
                                             body: Data("unrouted \(key)".utf8),
                                             connectedPeerAddress: "93.184.216.34")
        }
        let body = try route.file.map(MangaDexFixtures.body) ?? Data()
        return HostHTTPTransportResponse(statusCode: route.status, url: url,
                                         headers: route.headers, body: body,
                                         connectedPeerAddress: "93.184.216.34")
    }
}

private struct PublicResolver: HostNameResolving {
    func addresses(for host: String) async throws -> [String] { ["93.184.216.34"] }
}

/// The production factory's `host.http`, minus the network: real policy, real client.
final class MangaDexFixtureHost: ExtensionSourceHosting {
    let transport = MangaDexFixtureTransport()

    func capabilities(for declaration: SourceDeclaration,
                      operation: SourceOperation,
                      invocationID: UUID) -> [ExtensionHostCapability] {
        let client = HostHTTPClient(sourceID: declaration.qualifiedId,
                                    allowedOrigins: declaration.network.httpOrigins,
                                    transport: transport,
                                    resolver: PublicResolver())
        return [HostHTTPJSCapability(client: client)]
    }
}

@MainActor
final class MangaDexEngineTests: XCTestCase {

    private static let qualifiedID = "6f1d9c2e-4b7a-4c1e-9e3d-2a8b5c7d1f00:mangadex"

    private var lifecycle: SourceLifecycleRegistry!
    private var host: MangaDexFixtureHost!

    override func setUp() {
        super.setUp()
        lifecycle = SourceLifecycleRegistry()
        host = MangaDexFixtureHost()
    }

    private func declaration() throws -> SourceDeclaration {
        try PortFixtures.declaration(MangaDexFixtures.declarationJSON, qualifiedId: Self.qualifiedID)
    }

    private func makeSource() throws -> ExtensionSource {
        let declaration = try declaration()
        try lifecycle.register(declaration)
        return ExtensionSource(declaration: declaration,
                               script: MangaDexFixtures.script,
                               isNSFW: false,
                               lifecycle: lifecycle,
                               host: host)
    }

    func testTheDeclarationValidatesUnderHostAPI12() throws {
        let declaration = try declaration()
        XCTAssertEqual(declaration.network.httpOrigins, ["https://api.mangadex.org"])
        XCTAssertEqual(declaration.network.assetOrigins,
                       ["https://uploads.mangadex.org", "https://*.mangadex.network"])
    }
}
```

- [ ] **Step 4: Add the test file to the project**

```sh
cd ../Manga-Reader-mangadex-engine
xcp add-file "$PWD/MangaCarta.xcodeproj" --file "$PWD/MangaCartaTests/MangaDexEngineTests.swift" --targets MangaCartaTests
```

- [ ] **Step 5: Run it**

Run: `xcodebuild -scheme MangaCarta -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test -only-testing:MangaCartaTests/MangaDexEngineTests`
Expected: PASS. If validation rejects the declaration, the thrown message names the field. Fix the JSON, not the validator. `externalIds` and the wildcard both require 1.2, which is declared.

- [ ] **Step 6: Commit**

```bash
git add MangaCartaTests/__Fixtures__/mangadex MangaCartaTests/MangaDexEngineTests.swift MangaCarta.xcodeproj/project.pbxproj
git commit -m "test(mangadex-engine): declaration and fixture host"
```
Check `git diff --cached --stat MangaCarta.xcodeproj` first. Only the four `xcp` entries (plus the known synchronized-group reformat) belong.

---

### Task 2: Fixture capture, shared helpers, and `search` / `popular` / `newTitles`

**Files:**
- Create: `scripts/capture-mangadex-fixtures.sh`
- Create: `MangaCartaTests/__Fixtures__/mangadex/api/search-yotsuba.json`, `popular.json`, `new-titles.json`, `manga-no-english.json`
- Modify: `MangaCartaTests/__Fixtures__/mangadex/engine.js`
- Modify: `MangaCartaTests/MangaDexEngineTests.swift`

**Interfaces:**
- Consumes: Task 1's `MangaDexFixtureHost`, `makeSource()`.
- Produces (engine-internal, used by Tasks 3–5): `getJSON(context, cfg, path, pairs)`, `toListing(item, cfg)`, `offsetFrom(cursor)`, `listLimit(page)`, `pageResult(items, offset, limit, rawCount, total)`. Test constants `MangaDexFixtures.mangaID`, `MangaDexFixtures.malID`.

- [ ] **Step 1: Write the capture script and capture**

```sh
#!/bin/sh
# Re-captures the MangaDex JSON the engine tests run against. Manual only — CI never
# touches the network. Trim `limit` so fixtures stay small; then hand-edit only where a
# test says it needs an edge case, and say so in that test.
set -eu
API=https://api.mangadex.org
OUT="$(dirname "$0")/../MangaCartaTests/__Fixtures__/mangadex/api"
UA="MangaCarta-iOS/1.0 (fixture capture)"
mkdir -p "$OUT"
get() { curl -sf -A "$UA" "$API$1" | jq . > "$OUT/$2"; sleep 1; }

get "/manga?title=Yotsuba&includes%5B%5D=cover_art&limit=5&offset=0" search-yotsuba.json
get "/manga?order%5Brating%5D=desc&includes%5B%5D=cover_art&limit=5&offset=0" popular.json
get "/manga?order%5BcreatedAt%5D=desc&includes%5B%5D=cover_art&limit=5&offset=0" new-titles.json

MANGA_ID="${MANGA_ID:-$(jq -r '[.data[] | select(.attributes.links.mal != null)][0].id' "$OUT/search-yotsuba.json")}"
echo "MANGA_ID=$MANGA_ID"
get "/manga/$MANGA_ID?includes%5B%5D=author&includes%5B%5D=artist" detail.json
get "/manga/$MANGA_ID?includes%5B%5D=cover_art" listing.json
get "/chapter?manga=$MANGA_ID&translatedLanguage%5B%5D=en&order%5Bchapter%5D=asc&includes%5B%5D=scanlation_group&limit=100&offset=0" chapters-0.json
CHAPTER_ID="${CHAPTER_ID:-$(jq -r '.data[0].id' "$OUT/chapters-0.json")}"
echo "CHAPTER_ID=$CHAPTER_ID"
get "/at-home/server/$CHAPTER_ID" at-home.json
get "/chapter?translatedLanguage%5B%5D=en&order%5BreadableAt%5D=desc&includes%5B%5D=manga&limit=40&offset=0" latest-chapters.json
get "/manga/tag" tags.json
```

Run: `chmod +x scripts/capture-mangadex-fixtures.sh && scripts/capture-mangadex-fixtures.sh`.
Record the printed `MANGA_ID`, the `links.mal` value from `search-yotsuba.json` for that id, and `CHAPTER_ID`. Tasks 3–5 add their own routes to the files captured here.

Then hand-write `manga-no-english.json`: copy `search-yotsuba.json`, keep only its first item, set `attributes.title` to `{"ja-ro": "Yotsuba to!"}` and `attributes.links.mal` to `"yotsuba-to"`, and set `total` to `1`.

- [ ] **Step 2: Add constants and write the failing tests**

Add to `MangaDexFixtures` (values from Step 1):

```swift
    static let mangaID = "<MANGA_ID printed by the capture script>"
    static let malID = <that manga's links.mal, as an Int literal>
    static let chapterID = "<CHAPTER_ID printed by the capture script>"
    static let api = "https://api.mangadex.org"
```

(These three literals are the only values that cannot be written before capture. They must be real ids from the captured files.)

Add to `MangaDexEngineTests`:

```swift
    func testSearchMapsListingsWithCoverMalIdAndQualifiedSourceId() async throws {
        await host.transport.route(
            "\(MangaDexFixtures.api)/manga?title=Yotsuba&includes[]=cover_art&limit=5&offset=0",
            to: "search-yotsuba.json")
        let source = try makeSource()

        let results = try await source.search(title: "Yotsuba", limit: 5, offset: 0)

        let manga = try XCTUnwrap(results.first { $0.id == MangaDexFixtures.mangaID })
        XCTAssertEqual(manga.sourceId, Self.qualifiedID)
        XCTAssertEqual(manga.malId, MangaDexFixtures.malID)
        let cover = try XCTUnwrap(manga.coverURL?.absoluteString)
        XCTAssertTrue(cover.hasPrefix("https://uploads.mangadex.org/covers/\(MangaDexFixtures.mangaID)/"))
        XCTAssertTrue(cover.hasSuffix(".512.jpg"))
        XCTAssertFalse(manga.title.isEmpty)
    }

    func testPopularAndNewTitlesUseTheCompiledSourcesOrdering() async throws {
        await host.transport.route(
            "\(MangaDexFixtures.api)/manga?order[rating]=desc&includes[]=cover_art&limit=5&offset=0",
            to: "popular.json")
        await host.transport.route(
            "\(MangaDexFixtures.api)/manga?order[createdAt]=desc&includes[]=cover_art&limit=5&offset=0",
            to: "new-titles.json")
        let source = try makeSource()

        let popular = try await source.popular(limit: 5, offset: 0)
        let newTitles = try await source.newTitles(limit: 5, offset: 0)

        XCTAssertEqual(popular.count, 5)
        XCTAssertEqual(newTitles.count, 5)
    }

    // Review Focus 4
    func testNoEnglishTitleFallsBackAndASlugMalIdIsDroppedNotFatal() async throws {
        await host.transport.route(
            "\(MangaDexFixtures.api)/manga?title=Yotsuba&includes[]=cover_art&limit=5&offset=0",
            to: "manga-no-english.json")
        let source = try makeSource()

        let results = try await source.search(title: "Yotsuba", limit: 5, offset: 0)

        XCTAssertEqual(results.map(\.title), ["Yotsuba to!"])
        XCTAssertNil(results.first?.malId)
    }

    // Review Focus 3
    func testA429SurfacesAsRateLimited() async throws {
        await host.transport.route(
            "\(MangaDexFixtures.api)/manga?title=Yotsuba&includes[]=cover_art&limit=5&offset=0",
            status: 429, headers: ["Retry-After": "7"], file: nil)
        let source = try makeSource()

        do {
            _ = try await source.search(title: "Yotsuba", limit: 5, offset: 0)
            XCTFail("expected rate_limited")
        } catch let error as ExtensionSourceError {
            XCTAssertEqual(error, .invocation(.rateLimited))
        }
    }
```

Check the Swift case name before running: `grep -n "case rate" MangaCarta/Services/*.swift` (the enum is `ExtensionHostErrorCode`). Use whatever it is called.

- [ ] **Step 3: Run them to see them fail**

Run: `xcodebuild … test -only-testing:MangaCartaTests/MangaDexEngineTests`
Expected: the four new tests FAIL with the `unsupported` invocation error.

- [ ] **Step 4: Implement helpers and the three listing feeds**

Replace the skeleton's body (keep `fail`) with:

```js
  var DEFAULT_LIMIT = 20;
  var MAX_LIMIT = 100;          // /manga and /chapter reject limit > 100
  var OFFSET_WINDOW = 10000;    // MangaDex rejects offset + limit > 10000

  function hostError(code, message, retryAfterSeconds) {
    return { hostErrorCode: code, message: message, retryAfterSeconds: retryAfterSeconds };
  }

  function hostFailure(error) {
    var code = error && error.hostErrorCode ? error.hostErrorCode : "script";
    var message = error && error.message ? String(error.message) : String(error);
    return fail(code, message, error ? error.retryAfterSeconds : undefined);
  }

  // Drops null/undefined keys: the bridge refuses `undefined`, and the validator
  // refuses a null where it expects a string. An absent optional is an absent key.
  function compact(object) {
    var out = {};
    Object.keys(object).forEach(function (key) {
      if (object[key] !== null && object[key] !== undefined) { out[key] = object[key]; }
    });
    return out;
  }

  function queryString(pairs) {
    return pairs.filter(function (pair) {
      return pair[1] !== null && pair[1] !== undefined && pair[1] !== "";
    }).map(function (pair) {
      return encodeURIComponent(pair[0]) + "=" + encodeURIComponent(String(pair[1]));
    }).join("&");
  }

  // Statuses come back as values (Host API §4.1); this is where site semantics live.
  // 404 is "not found", which callers decide how to report.
  async function getJSON(context, cfg, path, pairs) {
    var query = queryString(pairs || []);
    var response = await context.host.http.request({
      url: cfg.apiBaseURL + path + (query ? "?" + query : ""),
      responseType: "text"
    });
    if (response.status === 404) { return null; }
    if (response.status === 429) {
      throw hostError("rate_limited", "MangaDex rate limit", response.retryAfterSeconds);
    }
    if (response.status < 200 || response.status >= 300) {
      throw hostError("http", "MangaDex answered HTTP " + response.status);
    }
    try {
      return JSON.parse(response.body);
    } catch (parseError) {
      throw hostError("script", "MangaDex response was not JSON");
    }
  }

  function offsetFrom(cursor) {
    if (cursor === null || cursor === undefined || cursor === "") { return 0; }
    var parsed = parseInt(cursor, 10);
    if (!isFinite(parsed) || parsed < 0 || String(parsed) !== String(cursor)) {
      throw hostError("invalid_request", "cursor is not an offset this engine issued");
    }
    return parsed;
  }

  function listLimit(page) {
    var parsed = typeof page.limit === "number" ? Math.floor(page.limit) : DEFAULT_LIMIT;
    return Math.max(1, Math.min(parsed, MAX_LIMIT));
  }

  // Host API §3.1: exactly one of a non-null nextCursor or exhausted: true.
  // `rawCount` is what MangaDex returned before any engine-side filtering.
  function pageResult(items, offset, limit, rawCount, total) {
    var next = offset + limit;
    var exhausted = rawCount < limit || next >= total || next + limit > OFFSET_WINDOW;
    return { items: items, nextCursor: exhausted ? null : String(next), exhausted: exhausted };
  }

  function requirePage(request) {
    if (!request.page || typeof request.page !== "object") {
      throw hostError("invalid_request", "paged operations require a page object");
    }
    return request.page;
  }

  function pickTitle(attributes) {
    var titles = attributes.title || {};
    if (typeof titles.en === "string" && titles.en.trim() !== "") { return titles.en; }
    var keys = Object.keys(titles);
    for (var i = 0; i < keys.length; i++) {
      if (typeof titles[keys[i]] === "string" && titles[keys[i]].trim() !== "") { return titles[keys[i]]; }
    }
    return "Unknown";
  }

  function alternateTitles(attributes, title) {
    var seen = {};
    seen[title] = true;
    var out = [];
    (attributes.altTitles || []).forEach(function (localized) {
      Object.keys(localized || {}).forEach(function (key) {
        var value = typeof localized[key] === "string" ? localized[key].trim() : "";
        if (value !== "" && !seen[value]) { seen[value] = true; out.push(value); }
      });
    });
    return out.length ? out : null;
  }

  // `links` is copied verbatim; the host validates `mal` and drops a slug with a warning.
  function externalIds(links) {
    var out = {};
    var any = false;
    Object.keys(links || {}).forEach(function (key) {
      if (typeof links[key] === "string" && links[key] !== "") { out[key] = links[key]; any = true; }
    });
    return any ? out : null;
  }

  function coverURL(item, cfg) {
    var art = (item.relationships || []).filter(function (rel) {
      return rel.type === "cover_art" && rel.attributes && typeof rel.attributes.fileName === "string";
    })[0];
    if (!art) { return null; }
    return cfg.coverBaseURL + "/covers/" + item.id + "/" + art.attributes.fileName + ".512.jpg";
  }

  function toListing(item, cfg) {
    var attributes = item.attributes || {};
    var title = pickTitle(attributes);
    return compact({
      id: item.id,
      title: title,
      description: attributes.description ? attributes.description.en : null,
      coverURL: coverURL(item, cfg),
      status: attributes.status,
      year: typeof attributes.year === "number" ? attributes.year : null,
      externalIds: externalIds(attributes.links),
      alternateTitles: alternateTitles(attributes, title),
      contentRating: attributes.contentRating
    });
  }

  async function mangaPage(request, context, cfg, pairs) {
    var page = requirePage(request);
    var limit = listLimit(page);
    var offset = offsetFrom(page.cursor);
    if (offset + limit > OFFSET_WINDOW) {
      return { ok: true, value: { items: [], nextCursor: null, exhausted: true } };
    }
    var body = await getJSON(context, cfg, "/manga", pairs.concat([
      ["includes[]", "cover_art"], ["limit", limit], ["offset", offset]
    ]));
    var data = (body && body.data) || [];
    var total = body && typeof body.total === "number" ? body.total : offset + data.length;
    return { ok: true, value: pageResult(data.map(function (item) { return toListing(item, cfg); }),
                                         offset, limit, data.length, total) };
  }

  async function invoke(operation, request, context) {
    var cfg = context.source.configuration || {};
    try {
      switch (operation) {
      case "search":
        return await mangaPage(request, context, cfg, [["title", request.query]]);
      case "popular":
        return await mangaPage(request, context, cfg, [["order[rating]", "desc"]]);
      case "newTitles":
        return await mangaPage(request, context, cfg, [["order[createdAt]", "desc"]]);
      default:
        return fail("unsupported", operation + " is not implemented by this engine");
      }
    } catch (error) {
      return hostFailure(error);
    }
  }
```

The fixture routes are written with literal `[]`, and the engine percent-encodes them. `FixtureSite.canonical` normalizes both sides the same way. If a route misses anyway, the test fails with `unrouted <url>`: compare the logged key with the route. Don't change the engine's encoding.

- [ ] **Step 5: Run the tests and confirm they pass**

Run: `xcodebuild … test -only-testing:MangaCartaTests/MangaDexEngineTests`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add scripts/capture-mangadex-fixtures.sh MangaCartaTests/__Fixtures__/mangadex MangaCartaTests/MangaDexEngineTests.swift
git commit -m "feat(mangadex-engine): listing feeds over host.http"
```

---

### Task 3: `latestUpdates` (two-step) and `tagBrowse`

**Files:**
- Create: `MangaCartaTests/__Fixtures__/mangadex/api/latest-manga.json`, `latest-chapters-dupes.json`, `latest-manga-shuffled.json`, `tag-romance.json`
- Modify: `engine.js`, `MangaDexEngineTests.swift`

**Interfaces:**
- Consumes: `getJSON`, `toListing`, `offsetFrom`, `listLimit`, `requirePage`, `pageResult` from Task 2.
- Produces: `updatesPage(request, context, cfg)`, `tagPage(request, context, cfg)` in the engine.

- [ ] **Step 1: Build the fixtures**

1. `latest-manga.json`: run `jq -r '[.data[] | .relationships[] | select(.type=="manga") | .id] | unique | .[]' latest-chapters.json`, then capture `/manga?includes%5B%5D=cover_art&ids%5B%5D=<id1>&ids%5B%5D=<id2>…&limit=<n>` for those ids **in first-seen chapter order**, capped at 20.
2. `latest-chapters-dupes.json` (hand-made, Review Focus 5): three chapters. Chapters `c-1` and `c-2` both relate to manga `m-a`; `c-3` relates to manga `m-b`. Newest first, `total: 3`.
3. `latest-manga-shuffled.json` (hand-made): two manga, `m-b` **before** `m-a`, each with a `cover_art` relationship and an English title.
4. `tag-romance.json`: capture `/manga?includedTags%5B%5D=<Romance tag id from tags.json>&order%5Brating%5D=desc&includes%5B%5D=cover_art&limit=5&offset=0`.

- [ ] **Step 2: Write the failing tests**

```swift
    // Review Focus 5
    func testLatestUpdatesDedupesToOneUpdatePerMangaInNewestChapterOrder() async throws {
        let api = MangaDexFixtures.api
        await host.transport.route(
            "\(api)/chapter?includes[]=manga&translatedLanguage[]=en&order[readableAt]=desc&limit=40&offset=0",
            to: "latest-chapters-dupes.json")
        await host.transport.route(
            "\(api)/manga?includes[]=cover_art&ids[]=m-a&ids[]=m-b&limit=2",
            to: "latest-manga-shuffled.json")
        let source = try makeSource()

        let updates = try await source.latestUpdates(limitTitles: 20, language: "en", offset: 0)

        XCTAssertEqual(updates.map(\.manga.id), ["m-a", "m-b"])
        XCTAssertEqual(updates.map(\.chapterId), ["c-1", "c-3"])
    }

    func testTagBrowseResolvesTheTagNameToItsId() async throws {
        let api = MangaDexFixtures.api
        await host.transport.route("\(api)/manga/tag", to: "tags.json")
        await host.transport.route(
            "\(api)/manga?includedTags[]=<Romance tag id>&order[rating]=desc&includes[]=cover_art&limit=5&offset=0",
            to: "tag-romance.json")
        let source = try makeSource()

        let results = try await source.mangaByTag(tag: "Romance", limit: 5, offset: 0)

        XCTAssertEqual(results.count, 5)
    }

    func testTagBrowseForAnUnknownTagIsAnEmptyFeedNotAnError() async throws {
        await host.transport.route("\(MangaDexFixtures.api)/manga/tag", to: "tags.json")
        let source = try makeSource()

        let results = try await source.mangaByTag(tag: "No Such Tag", limit: 5, offset: 0)

        XCTAssertTrue(results.isEmpty)
    }
```

The chapter over-fetch is `min(100, limit * 2)`, the compiled Source's rule, so `limitTitles: 20` → `limit=40`. Replace `<Romance tag id>` with the id from `tags.json` (`jq -r '.data[] | select(.attributes.name.en=="Romance") | .id'`).

- [ ] **Step 3: Run the tests; expect FAIL (`unsupported`)**

- [ ] **Step 4: Implement**

```js
  async function updatesPage(request, context, cfg) {
    var page = requirePage(request);
    var titles = listLimit(page);
    var chapterLimit = Math.min(MAX_LIMIT, titles * 2);
    var offset = offsetFrom(page.cursor);
    if (offset + chapterLimit > OFFSET_WINDOW) {
      return { ok: true, value: { items: [], nextCursor: null, exhausted: true } };
    }
    var chapters = await getJSON(context, cfg, "/chapter", [
      ["includes[]", "manga"], ["translatedLanguage[]", request.language || "en"],
      ["order[readableAt]", "desc"], ["limit", chapterLimit], ["offset", offset]
    ]);
    var rows = (chapters && chapters.data) || [];
    var order = [];
    var newest = {};
    rows.forEach(function (chapter) {
      var manga = (chapter.relationships || []).filter(function (rel) { return rel.type === "manga"; })[0];
      if (!manga || newest[manga.id] || order.length >= titles) { return; }
      newest[manga.id] = chapter.id;
      order.push(manga.id);
    });
    var byId = {};
    if (order.length) {
      var pairs = [["includes[]", "cover_art"]];
      order.forEach(function (id) { pairs.push(["ids[]", id]); });
      pairs.push(["limit", order.length]);
      var manga = await getJSON(context, cfg, "/manga", pairs);
      ((manga && manga.data) || []).forEach(function (item) { byId[item.id] = item; });
    }
    // MangaDex returns ids[] results in its own order; the feed's order is the chapters'.
    var items = order.filter(function (id) { return byId[id]; }).map(function (id) {
      return { chapterId: newest[id], listing: toListing(byId[id], cfg) };
    });
    var total = chapters && typeof chapters.total === "number" ? chapters.total : offset + rows.length;
    // The cursor is a *chapter* offset: dedupe shrinks the page, so a short item list is
    // not the end of the feed (MangaDexAPI.fetchLatestUpdates' note).
    return { ok: true, value: pageResult(items, offset, chapterLimit, rows.length, total) };
  }

  async function tagPage(request, context, cfg) {
    var page = requirePage(request);
    var tags = await getJSON(context, cfg, "/manga/tag", []);
    var wanted = String(request.tag || "").toLowerCase();
    var match = ((tags && tags.data) || []).filter(function (tag) {
      var name = tag.attributes && tag.attributes.name ? tag.attributes.name.en : null;
      return typeof name === "string" && name.toLowerCase() === wanted;
    })[0];
    if (!match) { return { ok: true, value: { items: [], nextCursor: null, exhausted: true } }; }
    return await mangaPage(request, context, cfg, [["includedTags[]", match.id], ["order[rating]", "desc"]]);
  }
```

Add to `invoke`'s switch:

```js
      case "latestUpdates":
        return await updatesPage(request, context, cfg);
      case "tagBrowse":
        return await tagPage(request, context, cfg);
```

`tagPage` calls `requirePage` to validate the request, and `mangaPage` validates it again; it does not use the returned value.

- [ ] **Step 5: Run the tests; expect PASS**
- [ ] **Step 6: Commit** `feat(mangadex-engine): latest updates and tag browse`

---

### Task 4: `detail`, `listing`, `chapters` (paginated, credited, deduped), `webURL`

**Files:**
- Create: `MangaCartaTests/__Fixtures__/mangadex/api/chapters-p0.json`, `chapters-p1.json` (hand-made)
- Modify: `engine.js`, `MangaDexEngineTests.swift`

**Interfaces:**
- Consumes: Task 2 helpers.
- Produces: `detail`, `listing`, `chapters`, `webURL` engine functions.

- [ ] **Step 1: Hand-make the two-page chapter fixtures** (Review Focus 2)

`chapters-p0.json`: `total: 102`, `data` of 100 chapters with ids `ch-001`…`ch-100` and `attributes.chapter` `"1"`…`"100"`. Chapter `ch-002` has `chapter: "1"`: it duplicates the number of `ch-001`, as a second group's upload. Every chapter has one `scanlation_group` relationship with `attributes.name` `"Group A"`, and `ch-001` has a second one, `"Group B"`. Generate the file with `jq -n`, not by hand:

```sh
jq -n '{result:"ok", total:102, data:[range(1;101) as $i | {
  id: ("ch-" + ($i|tostring|("00"+.)[-3:])), type:"chapter",
  attributes:{chapter: (if $i==2 then "1" else ($i|tostring) end), title:null,
    translatedLanguage:"en", publishAt:"2020-01-01T00:00:00+00:00", readableAt:"2020-01-01T00:00:00+00:00"},
  relationships: ([{type:"scanlation_group", id:"g-a", attributes:{name:"Group A"}}]
    + (if $i==1 then [{type:"scanlation_group", id:"g-b", attributes:{name:"Group B"}}] else [] end)) }]}' \
  > MangaCartaTests/__Fixtures__/mangadex/api/chapters-p0.json
```

`chapters-p1.json`: the same shape, `total: 102`, two chapters `ch-101`/`ch-102` numbered `"101"`/`"102"`, and a `null` `chapter` on `ch-102`.

- [ ] **Step 2: Write the failing tests**

```swift
    func testChaptersPageThroughEveryPageCreditGroupsAndCollapseDuplicateNumbers() async throws {
        let api = MangaDexFixtures.api
        for (offset, file) in [(0, "chapters-p0.json"), (100, "chapters-p1.json")] {
            await host.transport.route(
                "\(api)/chapter?manga=m-1&translatedLanguage[]=en&order[chapter]=asc&includes[]=scanlation_group&limit=100&offset=\(offset)",
                to: file)
        }
        let source = try makeSource()

        let chapters = try await source.chapters(mangaId: "m-1")

        XCTAssertEqual(chapters.count, 101)                     // 102 minus the duplicate "1"
        XCTAssertEqual(chapters.first?.id, "ch-001")            // first upload of "1" wins
        XCTAssertEqual(chapters.first?.groups, ["Group A", "Group B"])
        XCTAssertFalse(chapters.contains { $0.id == "ch-002" })
        XCTAssertEqual(chapters.last?.number, "?")              // unknown numbers are never merged
        XCTAssertNotNil(chapters.first?.date)
    }

    func testDetailCarriesAuthorsTagsAndRating() async throws {
        await host.transport.route(
            "\(MangaDexFixtures.api)/manga/\(MangaDexFixtures.mangaID)?includes[]=author&includes[]=artist",
            to: "detail.json")
        let source = try makeSource()

        let detail = try await source.mangaDetail(id: MangaDexFixtures.mangaID)

        XCTAssertFalse(detail.authors.isEmpty)
        XCTAssertEqual(Set(detail.authors).count, detail.authors.count)   // author == artist listed once
        XCTAssertFalse(detail.tags.isEmpty)
        XCTAssertNotNil(detail.contentRating)
    }

    func testListingRefetchesOneMangaAndMissingIsNil() async throws {
        let api = MangaDexFixtures.api
        await host.transport.route("\(api)/manga/\(MangaDexFixtures.mangaID)?includes[]=cover_art",
                                   to: "listing.json")
        await host.transport.route("\(api)/manga/gone?includes[]=cover_art",
                                   status: 404, headers: [:], file: nil)
        let source = try makeSource()

        let found = try await source.manga(id: MangaDexFixtures.mangaID)
        let missing = try await source.manga(id: "gone")

        XCTAssertEqual(found?.malId, MangaDexFixtures.malID)
        XCTAssertNil(missing)
    }
```

For `webURL`, find the `ExtensionSource` method that exposes it with `grep -n "webURL" MangaCarta/Models/ExtensionSource.swift`, and assert it returns `https://mangadex.org/title/\(MangaDexFixtures.mangaID)`. No HTTP route is needed; `webURL` makes no request.

- [ ] **Step 3: Run the tests; expect FAIL**

- [ ] **Step 4: Implement**

```js
  var MAX_CHAPTERS = 2000;      // the compiled Source's safety cap

  function groupsOf(chapter) {
    var names = [];
    (chapter.relationships || []).forEach(function (rel) {
      if (rel.type !== "scanlation_group" || !rel.attributes) { return; }
      var name = typeof rel.attributes.name === "string" ? rel.attributes.name.trim() : "";
      if (name !== "" && names.indexOf(name) < 0 && names.length < 10) { names.push(name); }
    });
    return names.length ? names : null;
  }

  function toChapter(chapter) {
    var attributes = chapter.attributes || {};
    return compact({
      id: chapter.id,
      number: attributes.chapter,
      title: attributes.title,
      publishedAt: attributes.publishAt || attributes.readableAt,
      language: attributes.translatedLanguage,
      groups: groupsOf(chapter)
    });
  }

  async function chapters(request, context, cfg) {
    var raw = [];
    var offset = 0;
    while (offset < MAX_CHAPTERS) {
      var body = await getJSON(context, cfg, "/chapter", [
        ["manga", request.listingId], ["translatedLanguage[]", request.language || "en"],
        ["order[chapter]", "asc"], ["includes[]", "scanlation_group"],
        ["limit", MAX_LIMIT], ["offset", offset]
      ]);
      if (!body) { return fail("http", "MangaDex has no such manga"); }
      var data = body.data || [];
      raw = raw.concat(data);
      offset += MAX_LIMIT;
      if (data.length === 0 || offset >= body.total) { break; }
    }
    // Several groups often upload the same number; keep the first. Unknown numbers
    // are never merged. Same rule as MangaDexAPI.fetchChapters.
    var seen = {};
    var items = raw.map(toChapter).filter(function (chapter) {
      if (chapter.number === undefined) { return true; }
      if (seen[chapter.number]) { return false; }
      seen[chapter.number] = true;
      return true;
    });
    return { ok: true, value: { items: items } };
  }

  async function detail(request, context, cfg) {
    var body = await getJSON(context, cfg, "/manga/" + encodeURIComponent(request.listingId),
                             [["includes[]", "author"], ["includes[]", "artist"]]);
    if (!body || !body.data) { return fail("http", "MangaDex has no such manga"); }
    var attributes = body.data.attributes || {};
    var authors = [];
    (body.data.relationships || []).forEach(function (rel) {
      if ((rel.type === "author" || rel.type === "artist") && rel.attributes &&
          typeof rel.attributes.name === "string" && authors.indexOf(rel.attributes.name) < 0) {
        authors.push(rel.attributes.name);
      }
    });
    var tags = (attributes.tags || []).map(function (tag) {
      var tagAttributes = tag.attributes || {};
      return compact({ id: tag.id, name: (tagAttributes.name || {}).en, group: tagAttributes.group });
    }).filter(function (tag) { return typeof tag.name === "string"; });
    return { ok: true, value: compact({
      description: attributes.description ? (attributes.description.en || "") : "",
      authors: authors,
      tags: tags,
      contentRating: attributes.contentRating
    }) };
  }

  async function listing(request, context, cfg) {
    var body = await getJSON(context, cfg, "/manga/" + encodeURIComponent(request.listingId),
                             [["includes[]", "cover_art"]]);
    if (!body || !body.data) { return { ok: true, value: null }; }
    return { ok: true, value: toListing(body.data, cfg) };
  }

  function webURL(request, cfg) {
    return { ok: true, value: { url: cfg.siteBaseURL + "/title/" + encodeURIComponent(request.listingId) } };
  }
```

Add the four cases to `invoke` (`webURL` is synchronous: `return webURL(request, cfg);`).

- [ ] **Step 5: Run the tests; expect PASS.** If `number: attributes.chapter` being `null` drops the key and the host reports it as `"?"`, then `chapters.last?.number == "?"` holds. That is the host's rule (§2.4), not the engine's.
- [ ] **Step 6: Commit** `feat(mangadex-engine): detail, listing, chapters, webURL`

---

### Task 5: `pages` with data-saver and asset-origin enforcement

**Files:**
- Create: `MangaCartaTests/__Fixtures__/mangadex/api/at-home-foreign.json` (hand-made)
- Modify: `engine.js`, `MangaDexEngineTests.swift`

**Interfaces:** Consumes Task 2's `getJSON`.

- [ ] **Step 1: Make the foreign-host fixture** (Review Focus 1). Copy `at-home.json` and set `baseUrl` to `"https://cdn.example.net"`.

- [ ] **Step 2: Write the failing tests**

```swift
    func testPagesHonourQualityAndPassTheWildcardAssetOrigin() async throws {
        let url = "\(MangaDexFixtures.api)/at-home/server/\(MangaDexFixtures.chapterID)"
        await host.transport.route(url, to: "at-home.json")
        let source = try makeSource()

        let saver = try await source.pageURLs(chapterId: MangaDexFixtures.chapterID, preferDataSaver: true)
        let original = try await source.pageURLs(chapterId: MangaDexFixtures.chapterID, preferDataSaver: false)

        XCTAssertFalse(saver.isEmpty)
        XCTAssertTrue(saver.allSatisfy { $0.path.contains("/data-saver/") })
        XCTAssertTrue(original.allSatisfy { $0.path.contains("/data/") })
        XCTAssertEqual(saver.count, original.count)
    }

    // Review Focus 1
    func testAnUndeclaredImageHostRejectsTheWholeChapter() async throws {
        await host.transport.route(
            "\(MangaDexFixtures.api)/at-home/server/\(MangaDexFixtures.chapterID)",
            to: "at-home-foreign.json")
        let source = try makeSource()

        do {
            _ = try await source.pageURLs(chapterId: MangaDexFixtures.chapterID, preferDataSaver: true)
            XCTFail("a page outside assetOrigins must reject the chapter")
        } catch is ExtensionSourceError {
            // expected: invalid_result/invalid_response from the host validator
        }
    }
```

The captured `at-home.json` must have a `baseUrl` under `*.mangadex.network` or equal to `https://uploads.mangadex.org` for the first test to mean anything. Check it: `jq -r .baseUrl`.

- [ ] **Step 3: Run the tests; expect FAIL**

- [ ] **Step 4: Implement**

```js
  async function pages(request, context, cfg) {
    var body = await getJSON(context, cfg, "/at-home/server/" + encodeURIComponent(request.chapterId), []);
    if (!body || !body.chapter || typeof body.baseUrl !== "string") {
      return fail("http", "MangaDex has no such chapter");
    }
    var saver = request.quality === "dataSaver";
    var files = (saver ? body.chapter.dataSaver : body.chapter.data) || [];
    var mode = saver ? "data-saver" : "data";
    return { ok: true, value: { items: files.map(function (file) {
      return { url: body.baseUrl + "/" + mode + "/" + body.chapter.hash + "/" + file };
    }) } };
  }
```

Add `case "pages": return await pages(request, context, cfg);`.

- [ ] **Step 5: Run the whole class; expect PASS**
- [ ] **Step 6: Commit** `feat(mangadex-engine): pages with data-saver`

---

### Task 6: Pin the SHA, run the full suite, publish the engine

**Files:**
- Modify: `MangaCartaTests/__Fixtures__/mangadex/index.json`, `MangaCartaTests/MangaDexEngineTests.swift`
- Create in `~/mangacarta-sources`: `mangadex/engine.js`, `index.json`

- [ ] **Step 1: Write the drift test**

```swift
    func testIndexPinsThisEngine() throws {
        let data = try Data(contentsOf: MangaDexFixtures.directory.appendingPathComponent("engine.js"))
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(MangaDexFixtures.bundle["scriptSHA256"] as? String, digest)
    }
```

- [ ] **Step 2: Run it; expect FAIL** (the all-zero placeholder)

- [ ] **Step 3: Pin the SHA**

```sh
shasum -a 256 MangaCartaTests/__Fixtures__/mangadex/engine.js
```
Put the digest into `index.json`'s `scriptSHA256`.

- [ ] **Step 4: Run the full unit suite**

Run: `xcodebuild -scheme MangaCarta -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test -only-testing:MangaCartaTests`
Expected: all PASS. A failure in a test you didn't write is simulator contention (memory: parallel workers share one simulator), so re-run once before investigating.

- [ ] **Step 5: Lint**

Run: `swiftlint lint --quiet MangaCartaTests/MangaDexEngineTests.swift`. Expected: no errors.

- [ ] **Step 6: Commit and open the PR** (app repo)

```bash
git add -A MangaCartaTests scripts
git commit -m "test(mangadex-engine): pin engine digest"
git push -u origin feat/mangadex-engine
gh pr create --title "MangaDex JSON-API extension engine (no-built-in slice 5)" --body "…"
```
Before `git add`, check `git diff --stat MangaCarta.xcodeproj/project.pbxproj`. Revert churn unrelated to the one added file.

- [ ] **Step 7: Publish to the engines repo** (only after the app PR's CI is green)

```sh
mkdir -p ~/mangacarta-sources/mangadex
cp MangaCartaTests/__Fixtures__/mangadex/engine.js ~/mangacarta-sources/mangadex/engine.js
cp MangaCartaTests/__Fixtures__/mangadex/index.json ~/mangacarta-sources/index.json
cd ~/mangacarta-sources
shasum -a 256 mangadex/engine.js      # must equal index.json's scriptSHA256
git config user.name   # must NOT be the owner's name; see memory "proxy-link engines repo"
git add mangadex/engine.js index.json
git commit -m "Add MangaDex engine"
git push origin main   # remote is the github-proxy-link SSH alias
```

- [ ] **Step 8: Live smoke test (manual, owner)**

In the simulator app: Settings → repositories → add `https://raw.githubusercontent.com/proxy-link/mangacarta-sources/main/index.json` → install MangaDex, and confirm the age sheet appears (`adult: mixed`). Then search "Yotsuba", open a chapter, and check the scanlation-group credit in the chapter list. This is the only step that proves the at-home host really falls under `*.mangadex.network`.

---

## Out of scope (later slices, per the handoff)

- Removing the compiled `MangaDexSource` from `builtInSources()` and migrating persisted `mangadex` ids.
- Removing the bundled WeebCentral package and publishing its engine to the same repository.
- A pinned host User-Agent; the MD@Home report path; `externalIds` on `ExtensionDetail`.
- Host API Amendment 5's flat-request compatibility shim (remove no later than slice 6).
