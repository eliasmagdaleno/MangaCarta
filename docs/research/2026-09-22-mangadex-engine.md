# MangaDex JSON-API engine: host fit and AUP obligations (2026-09-22)

Research for slice 5 of the "no built-in Sources" plan: MangaDex as an extension engine
(bundle script + `SourceDeclaration`, run by `ExtensionRuntime`, network via host `http`).
Code references are to `main` at `8e8f256`. Primary sources:
[API limitations](https://api.mangadex.org/docs/2-limitations/),
[Retrieving a chapter](https://api.mangadex.org/docs/04-chapter/retrieving-chapter/),
[Acceptable Usage Policy](https://api.mangadex.org/docs/) (docs landing page).

## Blockers / host changes needed

1. **Page images cannot pass the asset policy (blocker).** `/at-home/server/{id}` returns a
   `baseUrl` that MangaDex says "could be whatever else", varies by location, and is valid for
   only 15 minutes. `validatePages` requires every page URL's exact origin to be in
   `network.assetOrigins` (`MangaCarta/Models/ExtensionDomainSchemas.swift:322-346`, match at
   `:487-500`), and `DeclaredOrigin.canonicalized` accepts only literal `https://host[:port]`
   (`MangaCarta/Models/SourceDeclarationValidator.swift:601-640`). No static list can cover
   MD@Home nodes. Change needed: see §1.
2. **Scanlation groups cannot be credited (AUP blocker, already true today).** The AUP says
   you "MUST credit scanlation groups". `ExtensionChapter` has no group field
   (`ExtensionDomainSchemas.swift:140-150`) and `Chapter` has none either
   (`MangaDexAPI.swift:194`, `:222-225`); the compiled source drops groups today. Needed:
   an optional `groups: [String]` (or `scanlator`) on the chapter contract, plus UI showing it.
3. **No at-home report path.** The report goes to `https://api.mangadex.network/report` and is
   about *image* fetches, which the app performs itself, not the engine. Either the host
   reports (an image-load hook) or MangaDex is asked whether skipping it is tolerated. Soft,
   not a launch blocker: the compiled source never reported either.
4. **No host-side rate limiting.** Nothing in `HostHTTPClient` or `ExtensionRuntime` throttles
   per origin; the engine can only serialise its own calls within one invocation. Parallel
   invocations (library refresh + browsing) can exceed ~5 req/s. Needed: a per-Source (or
   per-origin) token bucket in the host, or a declared `rateLimit` in the declaration.
5. **User-Agent is acceptable as-is; no change required** (see §2), but worth a decision
   (ADR amendment) to pin an honest, identifiable host UA.

## 1. At-home image hosts vs declared origins

Two separate checks exist: `HostURLPolicy` (for `http` calls; exact origin set,
`MangaCarta/Services/HostURLPolicy.swift:66-86`) and `ExtensionDomainValidator.assetURL` (for
returned cover/page URLs). The engine's own calls — `/manga`, `/chapter`, `/at-home/server` —
all hit `https://api.mangadex.org`, so `httpOrigins` is fine. Covers are on
`https://uploads.mangadex.org`, a fixed origin, fine. Only page URLs break.

Minimal change: allow a **leading-label wildcard in `assetOrigins` only**, e.g.
`https://*.mangadex.network`, matched as "host has suffix `.mangadex.network`" (one or more
labels, never the bare apex, never across the registrable domain). Also list
`https://uploads.mangadex.org` literally, since the at-home server can hand back
`uploads.mangadex.org` itself. Keep `httpOrigins`/`browserOrigins` exact.

Security cost: small, because asset URLs are only *loaded as images* by the app, carry no
Source cookies or credentials, and still go through the HTTPS-only shape check. What is lost:
(a) a Source could point the reader at any host under the suffix — acceptable when the suffix
is owned by the site; (b) the reviewer can no longer read the full destination list from the
declaration; (c) a wildcard on a shared-hosting suffix (`*.cloudfront.net`, `*.github.io`)
would be near-open, so the validator should reject wildcards on public-suffix-like domains
(at minimum require ≥2 labels after `*.`, ideally a PSL check). Note the DNS public-address
check in `HostDestinationPolicy` does not apply to asset loads today; worth checking that the
image loader enforces it, or an MD@Home node could be spoofed to a private IP under the suffix.

Alternative with no policy change: fall back to the `uploads.mangadex.org` origin for pages.
MangaDex explicitly discourages hardcoding base URLs (bandwidth and IP bans), so reject this.

## 2. User-Agent

MangaDex: "The request MUST have a `User-Agent` header, and it must not be spoofed", and
requests "CANNOT have a `Via` header". The compiled client sends
`MangaCarta-iOS/1.0 (https://github.com/eliasmagdaleno/MangaCarta)` (`MangaDexAPI.swift:422-423`).

`HostHTTPClient` forbids author-set `user-agent` (`HostHTTPClient.swift:12-14`) and sets none
itself, so `URLSessionHostHTTPTransport` (`:290-330`) sends URLSession's default,
`MangaCarta/<build> CFNetwork/<v> Darwin/<v>`. That is truthful and identifies the app, and no
`Via` is added, so it satisfies the rule. Recommendation: have the host set one fixed,
honest UA for all `http` traffic (the existing MangaDex string, versioned) so MangaDex sees a
stable identifier and can contact the project; engines still may not override it. Do not
reuse `HostBrowser.userAgent` (`HostBrowser.swift:22`) — it is a Safari UA, i.e. spoofed.

## 3. AUP and limits, obligation by obligation

| Obligation | How it is met |
|---|---|
| Credit MangaDex | Declaration display name + source attribution already carried in-app (ADR-0003 Amendment 1, line 87); keep a "Data from MangaDex" credit on detail/reader. |
| Credit scanlation groups | **Gap** — needs chapter `groups` in contract + UI (Blocker 2). Engine gets them via `includes[]=scanlation_group` on `/manga/{id}/feed` or `/chapter`. |
| Honour removals | Engine reads live API only; removed chapters disappear on next fetch. Host must not cache page images beyond the session. |
| No ads / paid features | Product policy; app has none. Record it in PRODUCT.md or an ADR so it survives. |
| ~5 req/s global per IP; at-home 40/min | Engine serialises its calls and pages at `limit=100`; host needs a throttle (Blocker 4). Host already surfaces `retry-after` (`HostHTTPClient.swift:218`) and a `rate_limited` error (host API design §error codes); the engine should back off once, as `MangaDexAPI.swift:430-434` does. Cache at-home results ≤15 min to stay under 40/min. |
| No auth on image requests; no `Via` | Asset loads carry no cookies; host adds no `Via`. |
| at-home report | Soft gap (Blocker 3). |

## 4. Behaviour the engine must replicate

- **Covers:** `includes[]=cover_art` on every `/manga` query (`MangaDexAPI.swift:458, 476, 488,
  500, 568`), building `https://uploads.mangadex.org/covers/{id}/{file}.512.jpg`
  (`mangaCoverURL`). Returned as `coverURL`, must match `assetOrigins`.
- **Latest updates two-step:** `/chapter` ordered by `readableAt desc`, `includes[]=manga`,
  dedupe preserving order, then `/manga?ids[]=…&includes[]=cover_art`
  (`MangaDexAPI.swift:521-562`). Maps to the `latestUpdates` operation; the cursor must be the
  *chapter* offset, not a manga count (`:515-517`).
- **Chapter pagination:** `/chapter` caps `limit` at 100; page with `offset` until exhausted,
  `translatedLanguage[]=en`, `order[chapter]=asc`, and dedupe same-number uploads from multiple
  groups (`MangaDexAPI.swift:586-610`). One `chapters` invocation may make many requests — check
  it fits the runtime's per-invocation budget (`ExtensionRuntime.swift:8-26`, left unsettled).
- **Data-saver:** pages are `{baseUrl}/{data|data-saver}/{hash}/{file}` (`:620-630`; defaults to data-saver). The
  data-saver toggle is app state; engines have no preference input in Host API v1. Either add a
  declared boolean preference or ship full quality only.
- **Content rating / NSFW filter and tag lookup** (`/manga/tag` map, `MangaDexAPI.swift:328-340`)
  must be reproduced in script; no host gap.

## 5. External ids → `malId`

MangaDex `attributes.links` is `{ "mal": "25", "al": "…", "kt": …, "mu": … }`; values are
strings and may be slugs (`MangaDexAPI.swift:103`, `:141`). The listing contract already has
`externalIds: [String: String]` (`ExtensionDomainSchemas.swift:86, 364`) and maps
`externalIds["mal"]` to `Manga.malId` via `Int.init` (`:102`), so the engine should copy
`links` through verbatim as `externalIds` and let the host parse. Slice 4 still needs:
the same field on `ExtensionDetail` (so the detail path, not only browse, carries it), and
`al`→`anilistId` if the resolver wants it. Non-numeric `mal` values correctly yield `nil`.
