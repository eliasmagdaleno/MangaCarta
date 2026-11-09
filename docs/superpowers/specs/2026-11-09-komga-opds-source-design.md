# Komga / OPDS server Source design

**Date:** 2026-11-09
**Status:** Draft for owner review. Nothing here is decided until the owner answers the open
questions at the end. For current implementation state, see `CLAUDE.md` and the live handoff.
**Evidence baseline:** branch `eliasmagdaleno/spec-komga-opds` at `34c2257` (main after #365).
**Slug:** `komga-opds-source` (handoff queue item 10,
`docs/superpowers/handoff/2026-11-09-feature-queue.md:72`).

## Purpose and ownership

The local import design names a home-server client as "the next 'legitimate purpose', fitting the
same Source-shaped seam" (`docs/superpowers/specs/2026-09-22-local-import-design.md:318`; also its
non-goals at :22 and :11, where it notes Paperback is on the store as a Komga client). ADR-0025's
last consequence says the same: "a Komga/OPDS client, are future decisions"
(`docs/adr/0025-local-files-as-a-source.md:40`).

This spec covers how MangaCarta reads from **a server the reader runs themselves**: Komga, Kavita,
or anything else that serves an OPDS 1.2 catalog with the OPDS Page Streaming Extension (PSE). The
reader adds the server's address and credentials; its series show up as Works in Library and
Browse; chapters stream page by page into the existing reader.

This document owns *how* it is built. The decision that a user-configured server Source may be
compiled into the app belongs in an ADR (see open question 1). It cannot live only here
(`CLAUDE.md`, "Document ownership": "A decision that lives only in a handoff is not recorded"; the
same reasoning applies to a spec). Terms **Work**, **Listing**, **Listing key**, **Source**,
**Extension**, **Host API** and **Mint** are used as `docs/glossary.md` defines them.

### Goal

A reader with a Komga or Kavita server on their home network can:

1. add it in Settings by URL and username/password (or no auth);
2. browse and search its series from Home, and save them to Library;
3. read any book that the server streams page by page, with Basic auth on every page request;
4. get new-chapter notifications for saved series while the server is reachable; and
5. see a clear, non-alarming message when it is not reachable (away from home, server off).

### Non-goals (v1)

- **OPDS 2.0** (JSON feeds). Komga serves both v1.2 and v2 (komga.org/docs/guides/opds, fetched
  2026-11-09), but PSE, the piece that makes page streaming possible, is documented only for the
  v1.2 feed there. Deferred.
- **Downloading whole books** through an OPDS acquisition link (CBZ/PDF/EPUB download) and handing
  them to `LocalLibraryStore`. A good slice later (open question 6); not needed for streaming.
- **EPUB and PDF reading from a server.** Only image-page books streamed through PSE.
- **Server discovery via Bonjour.** The reader types the URL.
- **Matching server Works to MAL / AniList / MangaDex** in v1 (open question 4).
- **Komga features beyond reading**: collections, read lists, editing metadata, user admin.
- **Cross-device sync** through anything other than the server itself.

## 1. The code this builds on

Every claim below was checked by opening the file at `34c2257`.

**The seam.** `MangaSource` (`MangaCarta/Models/MangaSource.swift:18-94`) is String/Int in,
values out. Its optional capabilities default in an extension (`:130-169`), including
`isBrowsable` (`:131`, default `true`), `participatesInUpdates` (`:132`, default `true`, documented
at `:86` as covering "refresh, metadata upgrades, and external progress sync"),
`imageLoadReportTarget` (`:133`, default `nil`) and `homeFeedCapabilities` (`:165`, default all
three discovery feeds). `popular` has
no default and must be implemented (`:43`); `newTitles` and `latestUpdates` throw
`SourceError.unsupported` by default (`:146-152`).

**The precedent.** `LocalSource` (`MangaCarta/Models/LocalSource.swift:3-79`) is the one compiled
Source. It declares `isBrowsable = false` and `participatesInUpdates = false` (`:8-9`), returns no
Home feeds (`:11`), throws `unsupported` for `popular` (`:71`), and encodes its chapter ids as
`"<itemId>/<n>"`, parsing them back in `pageURLs` (`:59`, `:63-69`).

**Registration.** `SourceRegistry` keeps `builtIn` fixed (`MangaCarta/Services/SourceRegistry.swift:30`)
and `builtInSources()` returns `[LocalSource(store: .shared)]` (`:93-95`).
`setInstalledSources(_:)` **replaces** the whole non-built-in tail: `sources = builtIn + installed`
(`:108-109`), and its only caller is `ExtensionSourceRegistrar` (`ExtensionSourceRegistrar.swift:100`).
So a third kind of Source cannot simply be appended by another caller; the next Extension
lifecycle event would drop it. §4.3 adds a slot.

**Lookups are by Source id, and some by bare mangaId.** `source(id:)` (`SourceRegistry.swift:153-155`),
`sourceForRefresh` (`:191-194`), and refresh eligibility at
`LibraryRefreshCoordinator.swift:200-205` all key on the Source's id. But
`HistoryStore.latestEntry(forManga:)` (`HistoryStore.swift:203`) takes a **mangaId only**, and
`LibraryRefreshCoordinator.makeQueue` calls it with `listing.mangaId`
(`LibraryRefreshCoordinator.swift:240`). Two servers whose series ids collide would cross-wire
engagement. Kavita's OPDS paths use small integer ids, so a collision between two Kavita servers is
likely, not hypothetical. §3.2 makes server mangaIds globally unique for this reason.

**The Extension Host API cannot reach a home server, by design.**
- `HostDestinationPolicy.validatedHost` requires `https` and rejects URLs with user/password
  (`MangaCarta/Services/HostURLPolicy.swift:30-42`).
- `validateResolution` refuses any host that resolves to a non-public address (`:45-62`), using
  `HostIPAddress.isPublic` (`:190`), whose private ranges list starts at `:174`.
- `HostHTTPClient` forbids Extensions from setting `authorization` and `cookie` headers
  (`MangaCarta/Services/HostHTTPClient.swift:13`), and checks the connected peer is public (`:106`).
- Extension Source ids are minted by the installer from a repository UUID:
  `"<repositoryID>:<localId>"` (`ExtensionInstaller.swift:235`), against declarations a repository
  publishes, not a URL the reader types.

**Images.** `ImageCache.loadImage(for:reportTarget:)` (`MangaCarta/Services/ImageCache.swift:224-266`)
reads `file://` URLs directly (`:226-230`), then disk, then refuses anything
`HostDestinationPolicy.validate` rejects (`:236-241`), so **HTTP and private-IP URLs never load
today**. The network fetch builds a bare `URLRequest(url:)` with no headers (`:174`), refuses a
non-public connected peer (`:175-179`), and follows no redirects (`httpsOnlyRedirectHandler`,
`URLSessionDataFetcher.swift:34`). Both reader pages and covers go through it:
`CachedAsyncImage` (`Views/Components/CachedAsyncImage.swift:51`) and the reader
(`ReaderViewModel.swift:83`, `:190`).

**Keychain precedent.** `MALKeychainCredentialDataStore` (`MALCredentialStore.swift:114-...`)
stores one generic-password item under the bundle id as service, with
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, and `MALCredentialStore` deletes a leftover
Keychain item when no installation marker exists, so a reinstall does not inherit a sign-in
(`:106-108`). Its `description` is redacted (`:16-22`).

**Refresh failure handling.** A failed fetch is recorded per Listing with exponential backoff:
`UpdateStateStore.recordFailure` sets `blockedUntil` (`UpdateStateStore.swift:78-90`), and
eligibility skips a blocked Listing (`LibraryRefreshCoordinator.swift:203-204`). An unreachable
server therefore already degrades to "try later", silently.

**Capability flag users.** `participatesInUpdates` is read in exactly three places:
`LibraryRefreshCoordinator.swift:202` (refresh), `LibraryStore.swift:383` (library chapter-count
refresh), and `AppComposition.swift:376` (the `MetadataUpgradeQueue`'s `listingParticipates`).

**Info.plist.** `MangaCarta/Info.plist` has no `NSAppTransportSecurity` and no
`NSLocalNetworkUsageDescription` key (checked: its keys are BGTask identifiers, UT/document types,
in-place opening, `MALClientID`, URL types, background modes). Both are new here.

**Test fixtures.** `MangaCartaTests/__Fixtures__/` is resolved from `#filePath` and needs no
`project.pbxproj` edit (`MangaCartaTests/__Fixtures__/README.md`). The hermetic import UI test feeds
data through a DEBUG launch argument plus an environment variable
(`MangaCarta/MangaCartaApp.swift:308-325`, `-uitest-import-fixture` and
`MANGACARTA_UI_FIXTURE_BASE64`).

**Grep for prior art.** `rg -i "komga|opds|kavita|localnetwork|bonjour|URLCredential"` across
`MangaCarta/` and `MangaCartaTests/` finds nothing. Only docs mention Komga (ADR-0003:655,
ADR-0022:156, ADR-0025:40, the local import spec, the handoff). This is new code.

## 2. Decisions

### 2.1 v1 scope: OPDS 1.2 + PSE first, Komga REST later

| Option | For | Against |
|---|---|---|
| **A. OPDS 1.2 + PSE** (recommended) | One client covers Komga (PSE 1.2 on its v1.2 feed, per komga.org/docs/guides/opds) and Kavita (its OPDS docs describe "OPDS-PS" support, per wiki.kavitareader.com, fetched 2026-11-09), and other servers with the same extension. Atom XML parses with Foundation's `XMLParser`, which `ComicInfo` parsing already uses, so no dependency. Basic auth is the common denominator. | Thin metadata: no chapter numbers, no genres in a standard field, read progress is read-only at best (PSE `lastRead`). Feed layout differs between servers. |
| B. Komga REST first | Rich metadata (series status, number sort, genres), read-progress write-back, API keys (`X-API-Key`, per komga.org/docs/openapi/komga-api). | One server only. Kavita users get nothing. |
| C. Both at once | Everything. | Two parsers, two test fixture sets, two failure surfaces in one PR. Too big. |

**Recommendation: A for v1, with B added later as an optional "Komga flavour" on the same server
record** (slice 6). Reading is the product, and A gives every self-hoster reading. B adds sync for
the most popular server once A is solid. The server record carries a `flavour` field from day one,
so B needs no migration.

### 2.2 Where it lives: a compiled Source, not an Extension engine

| Option | Verdict |
|---|---|
| **A. Compiled `ServerSource` in the app, like `LocalSource`** (recommended) | Fits. |
| B. An engine in the engines repository, run by `ExtensionRuntime` | The Host API forbids each thing it needs (see below). |
| C. An engine plus a widened Host API that allows private hosts and auth headers for "server" declarations | Opens an SSRF route for every third-party engine. Rejected. |

Why B does not work, from the code (§1): Extensions may only reach HTTPS, public-address hosts
(`HostURLPolicy.swift:30-62`), may not set `Authorization` (`HostHTTPClient.swift:13`), and get their
origins from a repository-published declaration (`ExtensionInstaller.swift:235`), not from a URL the
reader types. A home server is plain HTTP on `192.168.x.x` with Basic auth, which fails all three.
These rules are what stop a malicious engine from probing the reader's router or NAS. Relaxing them
for one engine relaxes them for all, which is option C.

**Compatibility with ADR-0003 Amendment 6, stated explicitly.** Amendment 6 says the App Store build
ships "no built-in and no bundled Source" (`docs/adr/0003-extension-substrate.md:627`). Its reason is
"whose content the shipped app displays, and on whose permission" (`:638-640`). A server Source has
the same answer as `LocalSource` (ADR-0025, "Compatibility with ADR-0003 Amendment 6"): **the app
ships with no server, no catalog and no address; it shows only what the reader's own server serves,
at an address the reader typed.** It is a client protocol, like a web browser's HTTP, not a content
site. Amendment 6 itself cites Paperback as an App Store app positioned as "An Ad-Free Komga client
for iOS" (`:655-657`). So this is not an exception to Amendment 6; it is the case Amendment 6 points
to as acceptable.

This argument needs to be recorded in a new ADR (proposed **ADR-0029 — A reader's own server is a
compiled Source**) before slice 2 merges. This spec does not write it (open question 1).

### 2.3 One Source per server

Each configured server is its own `MangaSource` instance with id **`server:<uuid>`**, where `uuid`
is minted when the reader adds the server and lowercased. Not the URL: a server that moves from
`http://192.168.1.20:25600` to `https://komga.example.net` keeps its identity, its Listings, read
state and pins, the same rule Repositories follow (glossary, "Repository"). The `server:` prefix
cannot collide with an Extension id, which begins with a UUID (`ExtensionInstaller.swift:235`), or
with `local`.

Considered and rejected: one `opds` Source that serves every server and encodes the server in each
mangaId. It breaks fulfillment ranking and pins (ADR-0004), which rank *Sources*; two servers would
look like one.

## 3. Design

### 3.1 New types

All in synchronized groups (no `project.pbxproj` edit) unless stated.

| File | Type | Role |
|---|---|---|
| `Models/OPDSFeed.swift` | `OPDSFeed`, `OPDSEntry`, `OPDSLink`, `OPDSFeedParser` | Pure `XMLParser` over Atom + PSE namespaces. No networking. |
| `Models/ServerSourceIDs.swift` | `ServerMangaID`, `ServerChapterID` | Pure encode/parse of the opaque ids (§3.2). |
| `Models/ServerSource.swift` | `ServerSource: MangaSource` | The adapter. Holds a `ServerRecord` and a `ServerTransport`. |
| `Models/ServerSettingsViewModel.swift` | `@MainActor` view model | Add / edit / test / remove; errors as `errorMessage`. |
| `Services/ServerStore.swift` | `ServerStore`, `ServerRecord` | `Application Support/Servers/servers.json`, atomic writes. |
| `Services/ServerCredentialStore.swift` | Keychain secrets per server | Mirrors `MALCredentialStore`'s protocol + reinstall marker. |
| `Services/ServerTransport.swift` | `ServerTransport` protocol, `URLSessionServerTransport` | Authenticated GET (and later PATCH) to one server's origin only. |
| `Services/ServerRequestAuthorizer.swift` | `ServerRequestAuthorizing` | Lets `ImageCache` recognise a configured server's URL and authorise it (§3.5). |
| `Services/ServerSourceRegistrar.swift` | registrar | Builds `ServerSource`s from the store at launch and on change; calls `registry.setServerSources`. |
| `Views/Components/ServerSettingsSection.swift` | SwiftUI | The Settings section and add/edit sheet. In `Components/` so no pbxproj edit. |

### 3.2 Identity: how series become Works and Listings (ADR-0001)

- **A series is a Listing of its server's Source.** Saving or reading it mints a Work exactly as
  any remote title does (glossary, "Mint"); nothing special.
- **What counts as a series.** An OPDS entry whose `link rel="subsection"` (or a navigation link of
  `type` containing `kind=acquisition`) leads to a feed of books that carry PSE stream links. On
  Komga that is the series feed; on Kavita likewise. A plain navigation entry (Libraries, Publishers)
  is a folder, not a series.
- **mangaId = `ServerMangaID`**, the string `"<uuid>|<path>"` where `path` is the series feed's
  path and query **relative to the server root** (for example `/opds/v1.2/series/0A1B2C`).
  - Relative, so a server address change keeps every Listing.
  - Prefixed with the server UUID even though `sourceId` already carries it, because
    `HistoryStore.latestEntry(forManga:)` matches on mangaId alone (§1). Two Kavita servers would
    otherwise both have `/api/opds/.../series/12`.
  - Considered: the Atom `<id>` of the entry, which Atom says is permanent. It is not fetchable;
    using it would need a persisted id-to-href index that can go stale. The path is both stable and
    directly fetchable, so it wins.
  - Kavita puts the API key in its OPDS path (its docs: each user gets "a unique URL and Auth key").
    `ServerMangaID` must strip the record's catalog-root prefix and store only the part below it,
    so the key is never persisted into Library, History or `updates.json`. The pure parser test for
    this is AC 4.
- **chapterId = `ServerChapterID`**, `"<count>|<template>"`, where `template` is the PSE stream
  link's relative `href` with its `{pageNumber}` placeholder (and `{maxWidth}`, if present, filled in
  at request time) and `count` is the `pse:count` attribute. `pageURLs(chapterId:)` must work after
  a relaunch from History without first fetching the series, so the id has to carry everything; this
  follows `LocalSource`'s self-describing `"<itemId>/<n>"` (`LocalSource.swift:59`, `:63-69`).
  PSE page numbers are zero-based in Komga's implementation (to be confirmed against the fixture).
- **Chapter numbers.** OPDS has no chapter number. `ServerSource.chapters` derives one per book:
  the first decimal number in the title after a `Vol.`/`Volume`/`Ch.`/`Chapter`/`#` marker, else the
  first decimal anywhere in the title, else the book's 1-based position in feed order. Duplicates
  get `.1`, `.2` suffixes, the rule the local series design uses
  (`2026-09-22-local-import-design.md:425-427`). Read state is matched by chapter number (ADR-0027),
  so a positional number can shift if the server inserts an earlier book. That is the known weakness
  of option A; slice 6's Komga flavour replaces it with Komga's `numberSort`.
- **Covers.** The entry's `rel="http://opds-spec.org/image/thumbnail"` link, else
  `http://opds-spec.org/image`, resolved against the server and stored as an absolute URL in
  `Manga.coverURL`. Absolute here is fine: covers are re-fetched with each feed, and an old cover URL
  after an address change just shows the screentone placeholder until the next refresh.

### 3.3 `ServerSource` capability by capability

| Member | Behaviour |
|---|---|
| `id`, `name` | `server:<uuid>`; the reader's name for the server (default: the feed's `<title>`). |
| `isNSFW`, `declaresAdultTitles` | `false`, `false`. The content is the reader's own; the adult switch (ADR-0022) is about Sources the app helps the reader find. Open question 5. |
| `publishesExternalIds` | `false`. |
| `isBrowsable` | `true`: the server appears in the Home source picker. Unlike `local`, a server is a catalog you browse, not files you already chose. |
| `homeFeedCapabilities` | `[.newTitles]` when the root feed has a link with `rel="http://opds-spec.org/sort/new"` (Komga labels it "Latest series"), else `[]`. `popular` is never declared (OPDS has no popularity). |
| `homeRailTitles` | `["", "", "Latest series"]`, matching the protocol's three-slot shape (`MangaSource.swift:71-72`, default at `:164`). |
| `popular` | Throws `SourceError.unsupported("popular")`, as `LocalSource` does. |
| `newTitles(limit:offset:)` | Follows the `sort/new` link; pages by the feed's `rel="next"` links, mapping `offset` to a page count. |
| `search(title:limit:offset:)` | Uses the root feed's `rel="search"` OpenSearch description, filling `{searchTerms}`. A server with no search link throws `unsupported("search")`. Search results include only series entries (§3.2), never single books. (How the search screen presents `unsupported` today was not checked; slice 4 confirms it reads sensibly.) |
| `mangaDetail(id:)` | Fetches the series feed; description from the feed's `<subtitle>`/first entry `<summary>`/`<content>`, authors from `<author><name>`, tags from `<category label>`. `contentRating: nil`. |
| `manga(id:)` | Builds a `Manga` from the series feed's own header, so History and pins can recover a title. |
| `chapters(mangaId:)` | All books of the series, following `rel="next"` to the end (capped at 50 pages so a broken server cannot loop forever). Books with no PSE link are skipped and counted; if every book lacks one, throws `ServerSourceError.noStreamableBooks` (§5). |
| `pageURLs(chapterId:preferDataSaver:)` | Expands the template for `0..<count`, resolved against the record's *current* base URL. `preferDataSaver` fills `{maxWidth}` with 1600 when present, else ignored. |
| `imagePrefetchConcurrency` | 4. A home NAS is slower than a CDN, and four matches the refresh fan-out (`LibraryRefreshCoordinator.swift:190`). |
| `webURL(forManga:)` | `nil` in v1. (Komga has a web UI; slice 6 can return it.) |
| `participatesInUpdates` | `true`: a server gains books, so refresh and notifications should work. See §3.7 for the split this needs. |
| `imageLoadReportTarget` | `nil`. Image-load reports are a remote-Source operator feature (ADR-0003 Amendment 9); the reader is the operator here. |

### 3.4 Adding a server

**Settings → "Your servers"**, a new section placed directly above the repository manager
(`SettingsView.swift:224-226`), using `InkSectionHeader("Your servers", eyebrow: "<n> added")`.

The add sheet asks for:
1. **Address** — one field. Accepts `host:port`, `http(s)://host:port/path`, or the full OPDS URL.
   The view model normalises it and probes, in order: the URL as typed, then `<base>/opds/v1.2/catalog`
   (Komga), then `<base>/api/opds` (Kavita, which then needs the key-bearing URL the reader copies
   from Kavita), stopping at the first response that parses as an OPDS feed.
2. **Sign-in** — a segmented control: *Username & password* (default) or *None*. (API key only with
   the Komga flavour, slice 6.)
3. **Name** — prefilled from the feed's `<title>` after a successful probe; editable.

**Test and save** probes the server, shows the result inline ("Found *Komga* · 3 libraries" or the
specific error from §5), and saves only on success. A reader can save an unreachable server only by
choosing "Save anyway" after a failed probe, for the case of setting it up away from home.

**Storage.**
- `ServerRecord` (Codable, in `servers.json`): `id: UUID`, `name`, `catalogURL: URL` (the URL that
  probed as the root; for Kavita this contains the key, see below), `authMode: none | basic`,
  `username: String?`, `flavour: opds | komga`, `addedAt`, `allowsCleartext: Bool` (derived and
  stored at save, §3.6).
- **Secrets never touch `servers.json` or UserDefaults.** The password lives in the Keychain as a
  generic-password item: service = bundle id, account = `server.<uuid>.password`,
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, which is what MAL uses and what lets a
  background refresh read it after the first unlock. A Kavita catalog URL embeds its API key in the
  path, so `catalogURL` itself is a secret: `servers.json` stores it with the key segment replaced
  by `{key}`, and the key goes to the Keychain as `server.<uuid>.pathKey`. The probe detects this
  by Kavita's documented `/api/opds/<key>` shape.
- `ServerCredentialStore` reuses the MAL reinstall rule (`MALCredentialStore.swift:106-108`): with
  no installation marker, leftover server secrets are deleted, so a reinstall does not keep a
  password for servers whose `servers.json` is gone.
- `ServerRecord` and the credential type redact their `description`, as `MALStoredCredential` does.

**Multiple servers** are just several records. Each is its own Source in the picker, named by its
name, and each can be edited or removed independently.

**Removing a server** confirms ("Remove *Home Komga*? Its titles leave Browse and can't be read
until you add the server again. Library entries and reading history are kept."), deletes the record
and its Keychain items, and unregisters the Source. Listings, Library items and History stay,
exactly as for an uninstalled Extension (`SourceRegistry.source(for:)` returns `nil` for a known but
unregistered id, `:176-182`). To make that hold, `ServerSourceRegistrar` reports removed server ids
through `setKnownSourceIDs` alongside the lifecycle's (§3.3, §4.3). Re-adding a server is a new
UUID, so old Listings do not reattach automatically; open question 7.

### 3.5 Authenticated, private-network image loading through `ImageCache`

Today `ImageCache` will not load an HTTP URL, a private-IP URL, or anything needing auth (§1).
Options:

| Option | Verdict |
|---|---|
| A. Put credentials in the URL (`http://user:pass@host/...`) | `validatedHost` rejects userinfo (`HostURLPolicy.swift:33-34`); URLSession would also leak them into the disk-cache key, logs and History. Rejected. |
| B. A second image loader just for servers | Two caches, two prefetchers, and every view that shows a cover has to pick one. Rejected. |
| **C. An injected `ServerRequestAuthorizing` that `ImageCache` consults before its public-destination policy** (recommended) | One cache; the exception is explicit, narrow and testable. |

```swift
protocol ServerRequestAuthorizing: Sendable {
    /// Non-nil only when `url`'s scheme+host+port equals a configured server's origin.
    func authorizedRequest(for url: URL) async -> URLRequest?
}
```

`loadImage` changes as follows. Everything for every other URL stays exactly as it is.

1. Memory and disk lookup are unchanged. The disk key stays `SHA256(url.absoluteString)`
   (`ImageCache.swift:211-214`). Server image URLs contain no secret by construction (§3.2, the
   Kavita key is substituted only in the `URLRequest`, never in the URL the reader sees), so they are
   safe as keys.
2. **Before** `destinationPolicy.validate`, ask the authorizer. If it returns a request:
   - the request carries `Authorization: Basic …` (or nothing, for `authMode: none`) and, for
     Kavita, the key spliced into the path;
   - it goes through a **separate** `URLSessionDataFetcher` whose session configuration is
     `ImageCache.sessionConfiguration()` plus `httpShouldSetCookies = false`, and whose redirect
     handler allows a redirect only to the **same origin**;
   - the public-peer check (`:175-179`) is skipped for it, and nothing else is.
3. If the authorizer returns `nil`, today's path runs unchanged, including the refusal of HTTP and
   private addresses. **A remote Extension cannot use this exception**: it would need to hand out a
   URL whose origin matches a server the reader configured, and the request is built by the host,
   not by the Extension.
4. A 401/403 from a server is `ImageFetchError.invalidResponse` (returns `nil`, the reader shows its
   existing page-failure state) and also sets the server's `needsSignIn` flag, which Settings shows
   (§5).

`ServerTransport` (feeds) uses the same rules: same-origin only, Basic auth, private peers allowed,
no cookies. It is the only code that talks to a server.

**The `\.imageCache` environment value is the composition's cache** (`CLAUDE.md`, image-load
reports bullet). `AppComposition` constructs it with the authorizer at
`AppComposition.swift:448`; `ImageCache.shared` keeps the no-op default, so previews are unchanged.

### 3.6 HTTP, HTTPS and App Transport Security

Home servers are commonly plain HTTP on a private address (`http://192.168.1.20:25600`).

- **Info.plist gains `NSAppTransportSecurity` → `NSAllowsLocalNetworking = YES`, and nothing
  else.** No `NSAllowsArbitraryLoads`. Apple documents `NSAllowsLocalNetworking` as exempting local
  resources (unqualified host names, `.local` names and IP addresses) from ATS. Slice 1 must verify
  on device that `http://<private IPv4>:<port>` loads with this key alone and that
  `http://<public host name>` does not (AC 13).
- **Cleartext rule, enforced by the app, not just ATS:** `http://` is accepted only when the host is
  an IP literal that `HostIPAddress.isPublic` says is *not* public, or an unqualified / `.local`
  name. `http://komga.example.net` is refused at add time with "Use https:// for servers outside
  your home network." This matches what ATS would allow, so the reader gets a clear message instead
  of a low-level ATS failure.
- **Basic auth over HTTP sends the password readably on the local network.** The add sheet says so
  in one line under the field ("This server uses http://, so your password is sent unencrypted on
  your network.") when the address is `http://` and auth is on. It does not block it; that is how
  most home servers run.
- **Tailscale and other VPN addresses** (`100.64.0.0/10`) are not "local" to ATS's knowledge. With
  HTTPS (Tailscale's MagicDNS certificates) they work under the normal rules; plain HTTP to them is
  refused by the cleartext rule above. Recorded so nobody "fixes" it by adding arbitrary loads.
- **Self-signed certificates** are not accepted in v1: no trust-override UI. Open question 8.

### 3.7 Local network permission

iOS asks "MangaCarta would like to find and connect to devices on your local network" the first time
the app connects to a local address.

- **Info.plist gains `NSLocalNetworkUsageDescription`:** "MangaCarta connects to comic servers you
  add, such as Komga or Kavita, on your home network." No `NSBonjourServices` (no discovery in v1).
- **The prompt must appear at a moment that explains itself.** It is triggered by the add sheet's
  probe, after the reader has typed a local address and tapped *Test and save*, never at launch.
- **iOS gives no API to read this permission's state.** When a request to a private address fails
  with a connection error and the server has never answered on this device, the add sheet shows:
  "MangaCarta couldn't reach this address. If you declined local network access, turn it on in
  Settings → Privacy & Security → Local Network." with an *Open Settings* button
  (`UIApplication.openSettingsURLString`). This is a best-effort hint, worded as "if", because the
  same failure also means "server off".
- **Background refresh cannot prompt.** A background task to a local server before the permission
  is granted just fails and backs off (§1, `UpdateStateStore.swift:78-90`). The add-flow probe
  guarantees the prompt has already been answered in the foreground for any server that saved
  successfully.
- Loopback (`127.0.0.1`) does not trigger the prompt, which the hermetic UI test relies on not at
  all (it uses a stub transport, §7).

### 3.8 Browse, Library, and update polling

- **Browse.** `ServerSource` is browsable, so `visibleSources` (`SourceRegistry.swift:197-199`)
  includes it and the Home picker lists it by name. With only servers and `local` registered, the
  Home empty state no longer applies; Home shows the server's "Latest series" rail when declared,
  or the existing "this source has no feeds" state plus search.
- **Library and fulfillment** work unchanged. A Work with a MangaDex Listing and a Komga Listing
  is ranked by `FulfillmentRouter` like any two Listings (ADR-0004); a per-Work pin can choose the
  server. Joining a server Listing to an existing Work happens only through the existing manual link
  path (ADR-0005) in v1, because automatic resolution is off (§3.9).
- **Update polling: yes.** `participatesInUpdates = true`, so saved server series are refreshed by
  `LibraryRefreshCoordinator` and new books notify through `UpdateNotifier` (ADR-0021). Away from
  home, each fetch fails, the Listing backs off (`UpdateStateStore.swift:84-86`), and nothing is
  shown. That is the right behaviour, not a bug: a server is "unknown right now", never "zero
  chapters" (ADR-0004's rule that a `nil` count means unknown, `CLAUDE.md` "Fulfillment").
  `ListingCountCache` must therefore record nothing on a failed server fetch; it already only
  records successes, which a unit test pins (AC 11).

### 3.9 Splitting "participates in updates" from "participates in external matching"

`participatesInUpdates` today also gates the `MetadataUpgradeQueue` (`AppComposition.swift:376`),
which resolves titles against MAL and AniList by searching their titles. For a server Source that
would send the reader's private library titles to MAL/AniList. The local import design decided not
to do that for local Works (decision 6), and the same privacy reasoning applies here.

**Recommendation:** add one protocol requirement, `var participatesInExternalMatching: Bool { get }`,
whose default is `participatesInUpdates` (so `LocalSource` and every Extension behave exactly as
today), and use it at `AppComposition.swift:376` instead. `ServerSource` returns `updates = true`,
`matching = false`. It must be a protocol requirement, not extension-only, for the reason the NOTE
at `MangaSource.swift:67-69` gives. The doc comment at `:86` is updated to say refresh only.

Rejected: string-matching `server:` at the call site, which the local design already rejected for
`local` (`2026-09-22-local-import-design.md:233-236`).

### 3.10 Two-way read progress with Komga (slice 6, optional)

With `flavour: komga` (detected when the probe sees the Komga v1.2 path, or chosen by the reader),
the server record gains REST access to the same origin:

- **Read from server:** on `chapters(mangaId:)`, also fetch Komga's per-book read progress for the
  series (the books endpoint returns `readProgress { page, completed }` per book, per Komga's
  OpenAPI; exact paths to be confirmed against `/swagger-ui.html` on a test server during slice 6)
  and merge into `HistoryStore` with **furthest-wins**: the app never moves a reader backwards.
- **Write to server:** when the reader commits a page (the same moment `HistoryStore` records it),
  enqueue a `PATCH` of `{ page, completed }` for the book in a small per-server outbox
  (`ServerProgressOutbox`, same shape as `MALProgressOutbox.swift:65`), drained on foreground and
  after each refresh. An unreachable server keeps the item; it is coalesced to the latest page per
  book.
- **Chapter numbers** switch to Komga's `metadata.numberSort` for books on this flavour, which fixes
  the positional-number weakness (§3.2). This is a renumbering of existing read state, so slice 6
  must include a one-shot, idempotent migration by chapter id, the way the local series migration
  does (`2026-09-22-local-import-design.md:432-437`).
- Generic OPDS gets read-only progress at most, from PSE 1.2's `pse:lastRead`, and only as a hint
  on first open. v1 does not use it.

Open question 3 asks whether slice 6 is wanted at all.

## 4. Data and persistence changes

### 4.1 New files on disk

- `Application Support/Servers/servers.json` — `[ServerRecord]`, versioned (`"version": 1`),
  atomic write. Backed up with the device; contains no secret.
- Keychain items `server.<uuid>.password`, `server.<uuid>.pathKey`, device-only.
- (Slice 6) `Application Support/Servers/progress-outbox.json`.

### 4.2 Existing stores

No schema change. Library, History, `works.json`, `updates.json`, `ListingCountCache` and
`SourcePreferenceStore` all key on `(sourceId, mangaId)` and get ordinary strings.

### 4.3 `SourceRegistry`

Add `setServerSources(_ servers: [MangaSource])` and keep a third segment, so
`sources = builtIn + servers + installed`. `setInstalledSources` (`:108`) recomputes from the same
three parts instead of `builtIn + installed`. The active-source restoration logic at `:110-115`
runs after either setter. This is the only change to existing types other than §3.9's protocol
requirement, §3.5's `ImageCache` seam, and wiring in `AppComposition`.

### 4.4 Info.plist

Two keys, §3.6 and §3.7. `PrivacyInfo.xcprivacy` needs no change: no new required-reason API, and
data goes only to the reader's own server.

## 5. Errors and edge cases

All errors reach the UI as `errorMessage` strings on the view model (`CLAUDE.md`, Architecture).
`ServerSourceError: LocalizedError` cases and their messages:

| Case | When | Message |
|---|---|---|
| `unreachable` | connection refused / timed out / host not found | "Can't reach *Home Komga*. Check you're on the same network and the server is running." |
| `localNetworkMaybeDenied` | `unreachable` to a private address the server has never answered on this device | the §3.7 hint with *Open Settings* |
| `unauthorized` | 401/403 | "*Home Komga* didn't accept the username or password." + *Edit sign-in* |
| `notOPDS` | 200 but not an Atom feed | "This address answered, but it isn't an OPDS catalog." |
| `cleartextRefused` | `http://` to a public name | "Use https:// for servers outside your home network." |
| `noStreamableBooks` | a series whose books all lack PSE | "This server doesn't stream these books page by page." |
| `certificateUntrusted` | TLS trust failure | "This server's certificate isn't trusted by iOS." |

Edge cases:

- **Away from home.** Library still shows saved server titles with covers from the disk cache; the
  detail page shows chapters from the last successful fetch if the view model already has them, else
  `unreachable`. Pages already in `ImageCache`'s disk tier read offline; nothing else does. Downloads
  for offline are open question 6.
- **Server address changes.** Edit the server; ids are relative, so everything reattaches (§3.2).
  Cached cover and page images under the old address are re-fetched once.
- **Book re-scanned with a different page count.** `ServerChapterID` changes, so the old id's saved
  page position is orphaned; read marks survive because ADR-0027 matches by chapter number.
- **Feed pagination loops** are capped (§3.3).
- **Huge libraries** (thousands of series): `newTitles`/`search` page; nothing fetches a whole
  library. `chapters` pages to the end of one series only.
- **Password changed on the server.** 401 sets `needsSignIn`; Settings marks the server row with
  "Sign in again" (text, not colour alone); refresh backs off as usual.
- **Keychain unreadable** (device locked before first unlock in a background task): the transport
  throws, the Listing backs off; no prompt, no data loss.
- **Two servers serving the same series.** Two Listings, never merged automatically in v1.
- **Concurrency.** `ServerSource` is a `struct` of `Sendable` values like `LocalSource`;
  `ServerStore` and `ServerCredentialStore` are actors or lock-guarded classes as `MALCredentialStore`
  is (`final class … @unchecked Sendable`, `MALCredentialStore.swift:50`). Nothing needs isolated
  conformances, `nonisolated(nonsending)`, `@concurrent` or `Task.immediate`, so the design builds on
  CI's Xcode 16.4 / Swift 6.0.

## 6. Accessibility

Follows `DESIGN.md` (Inputs/Fields, Section Header, Source Stamp, "Don't" list) and the app's
existing VoiceOver conventions.

- The address field uses `.keyboardType(.URL)`, `.textContentType(.URL)`, no autocapitalisation or
  autocorrection; the password field uses `.textContentType(.password)` so Passwords autofill works.
- Probe results and errors are announced (`AccessibilityNotification.Announcement`) and stay on
  screen as text next to the field they concern, with the recovery button beside them (DESIGN.md,
  "Pair semantic state with explanatory text and an adjacent recovery action").
- The cleartext warning is a text line, not an icon or colour.
- A server row's state ("Reachable", "Can't reach", "Sign in again") is in its accessibility value,
  in words.
- The Source Stamp on a title from a server names the server (for example "HOME KOMGA"); its
  label is the server name in normal case so VoiceOver does not spell it out.
- Every control is reachable without a gesture; removing a server is a visible button plus the
  swipe action, never swipe alone.
- Dynamic Type: the add sheet is a `Form`, so it reflows at accessibility sizes.

## 7. Testing

**Fixtures.** Recorded OPDS XML in `MangaCartaTests/__Fixtures__/opds/`, resolved from `#filePath`
(no pbxproj edit, per that folder's README):

- `komga/` — root catalog, a "latest series" page with a `next` link, its second page, a series feed
  with three books (one without a PSE link), an OpenSearch description, and a search result.
  Captured from a local Komga test container with public-domain or original books only, with the
  server's ids kept and nothing else edited.
- `kavita/` — root and one series, with the API key in the path replaced by `TESTKEY0000`.
- `synthetic/` — hand-written minimal feeds for edge cases: no search link, a pagination loop, a
  missing `pse:count`, a malformed document, non-ASCII titles.
- Each directory's README records the server version and capture date, as `__Fixtures__/README.md`
  does for WeebCentral.

**Transport stub.** `ServerTransport` is a protocol; unit tests use an in-memory stub that maps
request paths to fixture files and records each request's headers.

**Unit tests (Swift Testing, `MangaCartaTests/`)** — each new file needs `xcp add-file … --targets
MangaCartaTests` (the group is not synchronized):

- `OPDSFeedParserTests.swift`
- `ServerSourceIDsTests.swift`
- `ServerSourceTests.swift`
- `ServerStoreTests.swift`
- `ServerCredentialStoreTests.swift`
- `ServerImageAuthorizationTests.swift`
- `ServerSettingsViewModelTests.swift`
- (slice 6) `KomgaProgressSyncTests.swift`

Existing files gain cases: `SourceRegistryTests.swift`, `LibraryRefreshCoordinatorTests.swift`,
`MetadataUpgradeQueueTests.swift`, `ListingCountCacheTests.swift`.

**UI test (hermetic, `MangaCartaUITests/ServerSourceUITests.swift`)** — also not synchronized, so it
needs `xcp add-file … --targets MangaCartaUITests`, as `LocalImportUITests.swift` did. A DEBUG-only
launch argument `-uitest-server-fixture komga` with the fixture XML passed in
`MANGACARTA_UI_SERVER_FIXTURE_BASE64` (one JSON object of path → body) registers a server whose
`ServerTransport` is the stub, following `importUITestFixtureIfRequested`
(`MangaCartaApp.swift:308-325`). The fixtures are supplied by the test, never bundled in the release
app. Rejected: a real HTTP listener inside the UI-test runner, which would exercise ATS and
URLSession too but adds a port and timing dependency to the hermetic CI suite; slice 1's device
check covers ATS instead. The test must not depend on grid position (CI's UI device is iPhone 16
Pro).

## 8. Acceptance criteria

Each maps to one named test. "U" = unit test in `MangaCartaTests/`; "UI" = hermetic UI test.

1. The Komga root fixture parses into a feed with its title, a `sort/new` link, a `search` link and
   its navigation entries. — U `OPDSFeedParserTests.parsesKomgaRootCatalog`
2. A series feed's books parse with PSE `href` template and `pse:count`; a book without PSE is
   reported as unstreamable, not dropped silently. — U `OPDSFeedParserTests.parsesPSEStreamLinks`
3. Malformed XML and a non-Atom HTML page both throw `notOPDS`, never crash. — U
   `OPDSFeedParserTests.rejectsMalformedAndNonAtom`
4. `ServerMangaID` round-trips, is relative to the catalog root, starts with the server UUID, and
   never contains the Kavita path key. — U `ServerSourceIDsTests.mangaIDIsRelativeUniqueAndKeyFree`
5. `ServerChapterID` round-trips and `pageURLs` expands `count` zero-based URLs against the current
   base URL, so an address change keeps the same ids. — U
   `ServerSourceTests.pageURLsSurviveAddressChange`
6. `chapters` follows `next` links, stops at the cap on a looping feed, numbers books from titles,
   falls back to position, and de-duplicates. — U `ServerSourceTests.chaptersPaginateAndNumber`
7. `search` uses the OpenSearch template; a server without one throws `unsupported("search")`. —
   U `ServerSourceTests.searchUsesOpenSearchTemplate`
8. Every feed request carries `Authorization: Basic` for `authMode: basic`, none for `.none`, and a
   cross-origin redirect is refused. — U `ServerSourceTests.transportAuthorizesSameOriginOnly`
9. `ImageCache` loads an `http://192.168.x.x` page URL only when the authorizer recognises its
   origin, adds the auth header, and still refuses the same URL when no server matches it. — U
   `ServerImageAuthorizationTests.privateHTTPLoadsOnlyForConfiguredOrigin`
10. A saved server series is refreshed and a new book produces an update event; an unreachable
    server backs the Listing off and produces no event. — U
    `LibraryRefreshCoordinatorTests.serverListingRefreshesAndBacksOffWhenUnreachable`
11. A failed server fetch writes nothing to the count cache (unknown, never zero). — U
    `ListingCountCacheTests.failedServerFetchRecordsNothing`
12. A server Listing is never enqueued for metadata upgrade, while an Extension Listing still is. —
    U `MetadataUpgradeQueueTests.serverListingNotMatchedExternally`
13. On a device, `http://<private IPv4>` loads with only `NSAllowsLocalNetworking`, and the app
    refuses `http://<public name>` with `cleartextRefused`. — U
    `ServerSettingsViewModelTests.refusesCleartextToPublicHost`, plus a one-time manual device check
    recorded in the slice-1 PR (ATS cannot be unit-tested).
14. Passwords are written to the Keychain, never to `servers.json` or UserDefaults; removing a
    server deletes its Keychain items; a missing install marker clears leftovers. — U
    `ServerCredentialStoreTests.secretsLiveOnlyInKeychain`
15. `servers.json` round-trips a v1 record and an unknown version is refused, not overwritten. — U
    `ServerStoreTests.roundTripsAndRefusesUnknownVersion`
16. The registry keeps server Sources across an Extension lifecycle event, lists them in
    `visibleSources`, and returns `nil` from `source(for:)` for a removed server's Listing. — U
    `SourceRegistryTests.serverSourcesSurviveInstalledSourceChanges`
17. The add flow probes typed → Komga path → Kavita path, saves on success, offers "Save anyway" on
    failure, and maps each failure to its §5 message. — U
    `ServerSettingsViewModelTests.probeOrderAndErrorMessages`
18. End to end: add the fixture server, see it in the Home picker, open a series, open a book,
    page 1 shows, page to the end marks the chapter read, remove the server and see the title stay
    in Library as unavailable. Screenshots attached at each step. — UI
    `ServerSourceUITests.addBrowseReadRemove`
19. (Slice 6) Komga progress is merged furthest-wins and a page commit enqueues one coalesced
    `PATCH` that survives an unreachable server. — U `KomgaProgressSyncTests.furthestWinsAndOutboxCoalesces`

## 9. Slices

Each merges on its own and leaves the app working. Slices 1–5 are v1.

1. **Parser + ids (pure).** `OPDSFeed`, `OPDSFeedParser`, `ServerMangaID`, `ServerChapterID`,
   fixtures. Plus the ATS device check (AC 13, manual half). *Accept:* AC 1–4.
2. **Store, Keychain, transport, `ServerSource`, registry slot, capability split.** No UI;
   registered only from tests. Requires ADR-0029 merged first. *Accept:* AC 5–8, 10–12, 14–16.
3. **`ImageCache` authorization seam + Info.plist keys.** *Accept:* AC 9.
4. **Settings UI: add, test, edit, remove; local-network hint; Source stamp naming.** *Accept:*
   AC 13 (unit half), 17.
5. **Hermetic UI test and the DEBUG fixture hook.** *Accept:* AC 18 on the hermetic CI suite.
6. **(Optional) Komga flavour: API key, `numberSort` chapter numbers with migration, two-way
   progress.** *Accept:* AC 19 and a migration test.

Slices 1–3 together are one engineer-week-sized PR if preferred; 4 and 5 are best as one PR.

## 10. Open questions for the owner

1. **Record "a reader's own server is a compiled Source" as a new ADR-0029 (rather than amend
   ADR-0025 or ADR-0003)?** Recommended: yes, a new ADR, accepted before slice 2. It is a new
   decision about a new kind of Source, citing Amendment 6 and ADR-0025; amending either would bury
   it.
2. **v1 scope: OPDS 1.2 + PSE first, Komga REST later (§2.1)?** Recommended: yes.
3. **Is two-way Komga read-progress sync (slice 6) wanted at all?** Recommended: yes, but after v1
   has been used on a real server for a while; it is the feature that makes Komga users stay, and it
   is the riskiest (it writes to the reader's server).
4. **Should server Works be matched to MAL/AniList (metadata, MAL progress) in v1?** Recommended: no,
   consistent with local decision 6 and to keep private library titles off third-party search; this
   needs the small `participatesInExternalMatching` split (§3.9). Revisit together with handoff
   item 7 (local matching).
5. **Do server Sources sit outside the adult-content switch (`isNSFW = false`,
   `declaresAdultTitles = false`)?** Recommended: yes. It is the reader's own content; the switch
   (ADR-0022) exists for Sources the app helps them find. The alternative, a per-server "contains
   adult titles" toggle, can be added later without migration.
6. **Offline: add "Download for offline" through OPDS acquisition links into the local library?**
   Recommended: not in v1; a follow-up slice that reuses `LocalLibraryStore` import. Until then,
   away from home means only already-cached pages.
7. **Re-adding a removed server: reattach old Listings automatically when the catalog URL matches?**
   Recommended: no in v1; it becomes a new server. Offer the reconnect prompt pattern
   (`InstalledSourceIDMigration`, ADR-0003 Amendment 7) later if people ask.
8. **Self-signed HTTPS certificates: support with a per-server "trust this certificate" prompt?**
   Recommended: no in v1. Plain HTTP on the LAN and real certificates (Tailscale, Let's Encrypt)
   cover the common setups, and a trust-override UI is a security surface worth its own design.
9. **App Store listing: mention Komga/Kavita/OPDS by name?** Recommended: yes, second after local
   import, as "Read from your own Komga, Kavita or OPDS server", which is the positioning Amendment 6
   cites Paperback for. App Review notes would need a reachable demo server or a screen recording;
   the owner decides which.
