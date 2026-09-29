# Image-load reports: design

- **Date:** 2026-09-28
- **Decision:** [ADR-0003 Amendment 9](../../adr/0003-extension-substrate.md). This document
  covers *how* to build it. It does not reopen what the amendment settles: opt-in, an explicit
  origin list, an endpoint inside `httpOrigins`, a fixed payload, Host API 1.3, fire-and-forget,
  and no reader switch.
- **Term:** [Image-load report](../../glossary.md).

## 1. The problem in one paragraph

A report needs four things at the moment an image download finishes: the Source it belongs to,
that Source's report endpoint, the response's `X-Cache` header, and how long the download took.
Today `ImageCache` has none of them. It loads by URL alone, and its fetch closure returns only
`Data`, discarding the response headers and doing no timing. The design gives the loader
those four things without making it Source-aware in general.

## 2. How a load learns its Source

**Chosen: the caller passes a report target.** A small value type travels with the load:

```swift
/// Where and for which origins a Source wants image-load reports. `nil` means none.
struct ImageLoadReportTarget: Sendable, Equatable {
    let sourceID: QualifiedSourceID
    let endpoint: URL
    let origins: [String]          // assetOrigins-syntax patterns, already validated

    func covers(_ url: URL) -> Bool  // same one-label wildcard matcher as assetOrigins
}
```

- `MangaSource` gains `var imageLoadReportTarget: ImageLoadReportTarget? { get }`. A protocol
  extension returns `nil` by default, so `LocalSource` and the compiled MangaDex code do not
  change. `ExtensionSource` builds the target from `declaration.network.imageLoadReports`. The
  protocol stays bridge-friendly: this is a value the host computes, not a method a bridge
  calls.
- `ReaderViewModel` already holds `source`. It reads the target once and passes it both to the
  prefetch closure and to the page views.
- `CachedAsyncImage` gains an optional `reportTarget:` that defaults to `nil`. Only the two
  reader call sites (`ReaderView.swift:722`, `:765`) pass one. Covers, history thumbnails and
  update rows pass nothing, so they are never reported.
- `ImageCache.loadImage(for:reportTarget:)` and `prefetch(_:maxConcurrent:reportTarget:)` take
  it too. Both default to `nil`, so existing callers compile unchanged.

**Rejected: look the Source up by URL.** The cache could match each URL against every installed
Source's `origins`. That is ambiguous when two Sources declare the same origin: which endpoint
gets the report, or do both? It would also sweep in cover loads through the same origin. The
cache should not have to answer questions it has no context for.

**Rejected: tag every page URL.** `pageURLs` could return `(URL, target)` pairs. That changes a
bridge-facing protocol method for every Source to carry data only one of them uses, and it
ripples through the reader's page arrays. Passing the target once per chapter is enough,
because every page of one chapter comes from one Source.

**Consequence worth stating:** covers are never reported, even from a reported origin. For
MangaDex this loses nothing, because covers come from `uploads.mangadex.org`, which Amendment 9's
`origins` excludes anyway.

## 3. Measuring a download

The internal fetch closure changes from returning `Data` to returning an outcome:

```swift
struct ImageFetchOutcome: Sendable {
    let data: Data
    let cacheHit: Bool      // X-Cache starts with "HIT" (case-insensitive)
}
```

- **Timing.** `loadImage` takes a `ContinuousClock` reading before each attempt and another when
  the attempt ends, success or throw. `duration` is the difference in whole milliseconds. It
  measures the complete retrieval, not time to first byte, as MangaDex asks.
- **Every attempt is a report.** The 429/503 back-off loop can make up to three attempts. Each
  one reached the node, so each one gets its own report: `success: false` for the throttled
  ones, then the final outcome. MangaDex's rule is per retrieval, not per page.
- **On failure** `bytes` is 0 and `cached` is `false`. The fetch step throws away a failed
  response's body, and nothing downstream needs its size. (Amended in step 3: this line
  used to say "whatever body arrived".)
- **Not reported:** memory and disk hits, `file:` URLs, a URL the destination policy refused,
  and a URL `target.covers(_:)` rejects. None of these is a download from a reported origin.
- **Also not reported (added in step 3):** a cancelled load (`CancellationError` or
  `URLError.cancelled`), which is the reader moving on, and a refused peer
  (`ImageFetchError.destinationRefused`), which is the host's own policy firing. Neither says
  anything about the node's health.
- **Decode failure does not change `success`.** The download succeeded; the image being bad is
  the app's problem, not the node's. Amendment 9 fixes `success` to mean the retrieval.
- **The test seam keeps its shape.** The existing `fetcher: (URL) async throws -> Data`
  initializer parameter is wrapped as `cacheHit: false`, so current `ImageCache` tests keep
  compiling. A new `outcomeFetcher:` parameter lets report tests supply headers.

## 4. Sending

A new `ImageLoadReporter` (Services, synchronized group) owns sending:

```swift
protocol ImageLoadReporting: Sendable {
    func report(_ report: ImageLoadReport, to target: ImageLoadReportTarget)
}
```

- `report` is **synchronous and non-throwing**. It starts a detached, utility-priority task and
  returns at once, so the image load never waits on it.
- The task sends through a `HostHTTPClient` built for that Source with
  `allowedOrigins: [endpoint origin]`, using the app's shared `HostRateLimiterRegistry`. So the
  report origin gets its own per-Source spacing and Amendment 8's 429 pause, and the endpoint
  passes the same public-address and redirect policy as every other host request.
- **No cookies.** The reporter gives each Source's report client its own empty
  `HostHTTPCookieJar`, never the jar the engine's HTTP uses. A report carries nothing the
  engine's session set.
- Body: `POST`, `Content-Type: application/json`, and exactly
  `{"url", "success", "cached", "bytes", "duration"}` with `bytes` and `duration` as integers.
  The response status is ignored. Any thrown error is swallowed and logged at debug level. There
  are no retries.
- **Bounded backlog.** A pause can hold reports for up to five minutes while the reader keeps
  turning pages. The reporter caps in-flight reports at 64 per Source and drops new ones past
  the cap. A lost report costs the operator a sample; an unbounded queue costs the reader
  memory.
- `ImageCache` receives the reporter by injection. Tests pass a recording fake.
- **The composition owns the cache (owner's ruling, step 4).** This line used to say
  production "passes the one built in `AppComposition`", but `ImageCache.shared` is a
  `static let` that nothing can hand a reporter to. So `AppComposition` builds
  `imageLoadReporter` over `hostRateLimiters` and one `imageCache` with it, and the app root
  injects that as `\.imageCache`. `CachedAsyncImage` reads the environment, and
  `ImageCache.shared` survives only as the key's default for previews. That follows the
  repo's "injected, not reached for" rule (CLAUDE.md, `SourceRegistry`). The rejected
  alternative was installing a reporter into `.shared` at launch.

## 5. The declaration

`SourceDeclarationValidator.network(from:selectedHostAPIVersion:)`:

- allows the new key `imageLoadReports` beside the existing three;
- rejects it below Host API 1.3 with `featureRequiresHostAPIVersion`, the same pattern as the
  1.2 wildcard gate;
- requires `endpoint` to be an absolute `https` URL whose canonical origin is in `httpOrigins`;
- requires `origins` to be non-empty. Each entry is canonicalized like an `assetOrigins` entry
  (wildcards allowed) and must be **covered by `assetOrigins`**: equal to one of its entries, or a
  literal origin that one of its wildcards matches.
- rejects unknown keys inside the object, as elsewhere.

`NetworkPolicy` gains `let imageLoadReports: ImageLoadReportPolicy?`, and `HostAPISupport.v1`
adds `HostAPIVersion(major: 1, minor: 3)`.

## 6. Out-of-repo and non-code work

- **The engine** (`proxy-link/mangacarta-sources`, pushed via the SSH alias only): add
  `https://api.mangadex.network` to `httpOrigins`, add
  `"imageLoadReports": {"endpoint": "https://api.mangadex.network/report", "origins": ["https://*.mangadex.network"]}`,
  and raise `hostAPI.minimum` to `1.3`. Publish it only after the app build that supports 1.3
  ships. Otherwise current builds see no version intersection and refuse the update.
- **Privacy:** update `docs/app-store/submission-copy.md` and any in-app privacy text to say that
  an installed Source may have the app send image-delivery statistics to that Source's operator.

## 7. Tests (test-first, per slice)

| Slice | Proves |
|---|---|
| Validator | 1.2 rejects the key; the endpoint must be in `httpOrigins`; an `origins` entry outside `assetOrigins` is rejected; wildcard coverage accepted; unknown inner key rejected. |
| `ImageLoadReportTarget.covers` | one-label wildcard matches like `assetOrigins`; `uploads.mangadex.org` is not covered by `*.mangadex.network`. |
| `ImageCache` | a network success reports `bytes`/`duration`/`cached`; `X-Cache: HIT-foo` → `cached: true`; disk hit, `nil` target, uncovered URL and policy refusal → no report; each 429 attempt reports `success: false`; decode failure still `success: true`. |
| `ImageLoadReporter` | exact JSON body and headers via `ScriptedHostHTTPTransport`; no `Cookie` header; a 429 on the endpoint pauses later reports (Amendment 8); the 65th in-flight report is dropped. |
| Reader wiring | `ReaderViewModel` passes the Source's target to prefetch; a Source with no target passes `nil`. |

## 8. Build order

1. Declaration: `ImageLoadReportPolicy`, validator, Host API 1.3.
2. `ImageLoadReportTarget` + `MangaSource.imageLoadReportTarget` + the `ExtensionSource`
   implementation.
3. `ImageFetchOutcome`, timing and the report hook in `ImageCache`.
4. `ImageLoadReporter` and its `AppComposition` wiring.
5. Reader wiring (`ReaderViewModel`, `CachedAsyncImage`, the two `ReaderView` call sites).
6. Privacy copy. Then the engine change, after the app ships.

Each step is one PR with its own tests. Steps 1–2 change no runtime behaviour, and nothing is
sent until step 5 connects a Source's target to real loads.
