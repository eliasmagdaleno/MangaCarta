# ADR-0003 — Extensions are JavaScript: JavaScriptCore for logic, WKWebView for fetching

- **Status:** Accepted in principle (2026-07-24); host API undesigned. **Amendment 1 below
  narrows "ship zero built-in aggregator sources": MangaDex stays built in as the resolution
  bridge, and extensions are additive. Amendment 5 (2026-09-21) removes the compiled WeebCentral:
  the shipping app registers MangaDex alone.**
- **Related:** ADR-0001, ADR-0002, ADR-0004, ADR-0016, ADR-0022

## Context

The goal is user-installable sources, in the shape Paperback and Aidoku have — the app ships as
an empty reader and the user adds source extensions themselves. Distribution target is the **App
Store, plus TestFlight for other users**, which constrains the design more than the engineering
does.

iOS forbids shipping executable code downloaded after review: no dylibs, no JIT. The established
workaround, and the reason both comparable apps look the way they do, is an **interpreter plus a
defined host API** — interpreted content is not executable code for guideline purposes. Paperback
runs JavaScript; Aidoku runs WebAssembly.

The codebase is already most of the way here, by earlier design rather than by accident:

- `MangaSource` was deliberately written bridge-friendly — "every parameter is an `Int`/`String`
  and every return value is a value/Codable domain type … keeps the door open for a future
  dynamic-extension runtime (JS/WASM)" (`MangaSource.swift`).
- `WebViewService` already loads a page in a shared off-screen `WKWebView`, injects a JS script
  whose final expression is a `JSON.stringify(...)`, and decodes the result into Codable DTOs.
- **`WeebCentralSource` is effectively a hardcoded JavaScript extension already** — its
  per-page extraction scripts are co-located raw strings, explicitly noted as "the volatile part
  when the site redesigns."

## Decision

**Two substrates, one extension model.**

- **JavaScriptCore runs extension logic** — parsing, URL construction, mapping a site's shape
  onto `MangaSource`. It is a system framework, needs no WebView, and bridges cleanly to the
  `String`/`Int`-in, Codable-out contract `MangaSource` already has.
- **`WKWebView` performs fetches that require being a browser.** This is not an optimization:
  Cloudflare-protected sources can only be fetched by something with real cookies, a real TLS
  fingerprint, and a real DOM. `WebViewService` already holds `cf_clearance` in a persistent data
  store and surfaces interactive challenges.

An extension is therefore **one kind of thing** (a JS bundle) with **two fetch strategies**
available to it — plain HTTP, or via the WebView — chosen per request by the extension, not two
different extension formats.

WebAssembly is rejected: strongest sandboxing, but the worst authoring experience, and the
authoring cost is paid on every source written.

## Consequences

- **The host API is the real work, and it is a forever contract.** The functions exposed to
  extension code — `fetch`, `fetchViaWebView(url, script)`, `log`, `storage`, and the
  `MangaSource`-shaped entry points — cannot be broken once third-party extensions exist.
  Extension systems die of API churn far more often than of engine choice. **Undesigned; this
  ADR does not decide it.**
- **Ship zero built-in aggregator sources.** The app is an empty reader; the user adds extension
  repos. This follows from the distribution target: copyright complaints, not guideline 2.5.2,
  are the more common takedown vector for reader apps. It also means the **extension installer
  and repo format are day-one features**, not a later addition.
- `WeebCentralSource` becomes the migration proving-ground: porting it from a compiled Swift
  source to a JS extension validates the host API against a real, Cloudflare-protected site.
- A JS layer sits between the app and every source — new failure modes (script errors, bad
  extension output) that the typed Swift sources cannot currently produce.

## Sequencing

This ADR is **third** in the build order, deliberately. Per ADR-0001 and ADR-0002, Work/Listing
identity is buildable today against the two existing sources, and the extension system exists to
make that identity *pay off at scale*. Building extensions first, before Works exist, means every
new source multiplies duplicate entries with nothing to reconcile them.

## Amendment 1 — MangaDex stays built in (2026-08-31)

"Ship zero built-in aggregator sources" above is **narrowed**: the app ships with MangaDex
registered, and the empty-reader posture applies to every *other* source.

The reason is not convenience. ADR-0016 makes MangaDex the **resolution bridge** — it is the one
source whose entries carry `links.mal`, which is what lets the app know that a title here and a
title there are the same manga. For You, More Like This and MyAnimeList progress sync are all
built on top of that bridge. An install with no MangaDex is not an empty reader; it is a reader
with recommendations that silently return nothing and a MAL list that never moves, and the reader
has no way to know that installing one particular extension is what would fix it.

The original consequence was reasoned from a takedown argument — copyright complaints being the
likelier vector for reader apps than guideline 2.5.2. That argument still stands, and this
amendment does not weaken it: MangaDex is an API with public documentation and a required
attribution, which the app carries, and it is the source the app is already named around in its
own README.

So **extensions are additive**. The built-in set is the bridge and nothing more; everything a
reader adds, they add themselves. If the bridge is ever replaced — a metadata provider that does
not need a chapter source attached — this narrowing should be revisited rather than inherited.

This was decided during the fulfillment work and recorded only in a session handoff, which under
`CLAUDE.md`'s document-ownership rule is not a record at all: handoffs are archived, and archived
handoffs are explicitly never to be worked from. Phase 2's host API design will amend this ADR
again, and that amendment should assume MangaDex is present.

## Amendment 2 — the Host API is declarative, capability-based, and configuration-first (2026-09-02)

The substrate decision above stands. This amendment settles the architectural boundary that the
original ADR deliberately left undesigned. The versioned wire contract is specified in the
[Phase 2 Host API design](../superpowers/specs/2026-09-02-host-api-design.md); this amendment owns
the decisions and their reasons.

### Context

The first extension cannot define the architecture by accident. Paperback's catalog evidence shows
that most sources are instances of reusable site themes: 55 generic-theme sites and 23 bespoke
ones, with Madara alone accounting for 29 sites. A design in which every installed Source must be a
separate hand-written program would make configuration masquerade as code, multiply review and
update work, and prevent a theme fix from repairing every site that uses it.

The existing Swift seam also cannot simply be exported. It mixes discovery metadata, UI copy,
optional behavior inferred in several ways, Foundation values, source-specific pagination, and an
unbounded `throws` channel. `SourceContext` exposes no plain HTTP capability, while its WebView
capability accepts a Swift metatype and returns a decoded Swift value. Those are useful internal
seams, not a stable cross-runtime contract.

### Decision

**An Extension is an engine; a Source is a manifest-declared, configured instance of that engine.**
One installed bundle may declare many Sources and may apply one executable theme engine to many
configuration records. Source identity, display metadata, adult classification, supported
operations, language behavior, allowed origins, and presentation hints are declarative. The host
can therefore inspect, gate, and register a Source without executing untrusted code. Executable
entry points implement only the operations declared for that Source and receive its immutable
configuration as invocation context.

**The Host API is a versioned message boundary, not a projection of `MangaSource`.** Requests,
results, and failures cross as JSON-compatible values validated by the host. The host owns mapping
to Swift domain types, source-id stamping, input validation, URL policy, and user-facing error
copy. Optional behavior is declared, never discovered by calling code and waiting for an
unsupported error. Compatibility is negotiated from an Extension-declared Host API range; no
best-effort execution occurs when the ranges do not intersect.

**Host services are explicit capabilities with least authority.** Version 1 exposes plain HTTP,
browser extraction, bounded key/value storage, and redacted structured logging. Network access is
restricted to manifest-declared HTTPS origins. Browser identity and cookies are host-owned and
partitioned by Source plus origin; an Extension cannot set the browser user agent or access another
Source's browser state. Secrets and arbitrary filesystem access are not part of version 1.

**The host schedules and bounds all work.** Extensions may not create detached host operations.
Cancellation ends the invocation and invalidates later callbacks. HTTP concurrency, origin rate,
response size, browser occupancy, script time, and image prefetch width are host-enforced budgets;
manifest values are requests within host clamps, not authority. Exact numeric defaults are tuning
policy and require measurement, so they are not frozen into this ADR.

**Interactive browser work is foreground-only.** A background invocation that encounters a
challenge returns a distinct interaction-required outcome without presenting UI. A foreground
caller may retry and the host identifies the Source and origin before showing the browser. Decline,
timeout, cancellation, and background deferral remain distinct outcomes.

**Stable Source ids are repository-qualified and immutable.** The installer derives the installed
identity from repository identity plus the manifest's local Source id and rejects collisions.
Updates cannot rename that identity. Disablement or uninstall makes the Source unavailable without
rewriting Listings or pins; reinstalling the same qualified identity reconnects them. Replacement
by an unrelated repository is a different identity even if it uses the same local id.

**Adult classification is mandatory, declarative, and fail-closed.** A missing or invalid
classification prevents Source registration. Repository review may strengthen a declaration but
cannot weaken it; the host may also elevate a specific Listing when validated output marks it
adult. The trust and signing policy by which repositories earn review status belongs to the later
repository-format design and remains open until that evidence exists.

### Alternatives rejected

- **One program per Source.** Rejected because it duplicates generic-theme logic and makes one
  site configuration the unit of executable maintenance.
- **Export `MangaSource` directly.** Rejected because Swift defaults, metatypes, Foundation URLs,
  unconstrained errors, and source-specific paging do not form a stable language-neutral ABI.
- **Infer capabilities from exported functions or failures.** Rejected because the host must know
  what it may display and schedule before running extension code, and failure is not discovery.
- **Give extension code a general network/browser/filesystem object.** Rejected because origin,
  privacy, resource, and lifecycle policy would become unenforceable or depend on author
  cooperation.
- **Share one browser identity across Sources.** Rejected because cookies can carry authentication
  or tracking state and must not become an undeclared cross-extension communication channel.
- **Permit best-effort version mismatches.** Rejected because silent semantic drift is harder to
  diagnose and less safe than refusing an incompatible Extension with an actionable reason.
- **Trust `adult: false` as an optional author hint.** Rejected because that value controls source
  visibility and notification disclosure; absence cannot safely mean non-adult.

### Consequences

- Theme engines and their configurations can evolve independently: one engine fix can repair many
  Sources without inventing a new Host API operation.
- The runtime adapter will be deeper than a JavaScriptCore wrapper around `MangaSource`; it needs
  manifest validation, message validation, capability brokers, scheduling, and domain mapping.
- Existing compiled Sources remain internal adapters. MangaDex remains built in under Amendment 1;
  the WeebCentral port is the first conformance test for the external contract.
- Repository installation must establish repository identity, validate Source-id uniqueness, and
  define review/signing metadata. That work is deliberately sequenced after the Host API contract.
- Version 1 omits credentials and arbitrary cache files. Adding either later requires a new
  optional Host API capability rather than widening storage or network authority implicitly.

## Amendment 3 — per-Source browser state is a `WKWebsiteDataStore(forIdentifier:)`, and background invocations never present UI (2026-09-03)

Amendment 2 and the [Phase 2 Host API design](../superpowers/specs/2026-09-02-host-api-design.md)
both stand unchanged. This amendment closes **evidence gate 2** — the design's second deliberately
open gate, "the WebKit mechanism that provides both persistent clearance and strong per-Source
isolation on iOS 17.5" — and fills the one contract gap the prototype had to resolve to answer it.

### Context

Section 9 of the design requires two things that pull against each other. Cookies and website data
must be **partitioned by qualified Source id and origin**, so that two configured Sources on the
same site cannot read each other's state. And Cloudflare clearance must **survive relaunch**, or
the reader re-solves a challenge every time they open the app.

The shipped `WebViewService` sits on one side of that tension deliberately: one shared
`WKWebsiteDataStore.default()` plus a pinned User-Agent, chosen precisely so `cf_clearance` lives
across launches. That is real persistence bought with zero isolation. The design named the fallback
in advance — "separate nonpersistent stores plus explicit loss of cross-launch clearance, never a
shared global store" — because it could not say whether the deployment target offered anything
better.

It does.

### Decision

**Each Source gets its own persistent `WKWebsiteDataStore(forIdentifier:)`.** The fallback is not
taken, and the shared default store is rejected for Extension-backed Sources.

- The identifier is a **name-based (version 5) UUID over a fixed host namespace and the qualified
  Source id**. The same Source resolves to the same store on every launch with no mapping to
  persist and no migration to write, and distinct Sources cannot collide by accident. Version 5
  also forces a nonzero version nibble, which sidesteps `dataStoreForIdentifier:`'s documented
  "throws exception if identifier is 0". **The namespace is permanent**: changing it orphans every
  reader's clearance at once.
- **The store must be attached to a `WKWebView`.** A `WKWebsiteDataStore` held on its own, with no
  web view ever constructed against it, does not become durable — see the evidence below.
- **A freshly opened store's cookie jar must be warmed up before it is read.** Its on-disk cookies
  load asynchronously, and `getAllCookies` issued before that finishes returns an empty jar with no
  error. Any host code that decides "this Source has no clearance" from an immediate read is
  reading a race, not a fact.

**Section 4.2's `interaction` parameter has exactly two cases: `allowForeground` (the default the
design already shows) and `never`.** The design's signature named only the default while §9 and
acceptance criterion 8 both require a mode that presents nothing; the enum was missing from the
contract, and this is the slice with the evidence to settle it.

The two cases are an **author** request, not a statement about app state — an engine cannot know
whether the app is foregrounded, and §9 makes the no-UI rule a property of the invocation. So the
effective policy is the **intersection** of the author's request and the host's own invocation
context: a sheet may be presented only when the author passed `allowForeground` *and* the host is
running foreground. `never` exists for speculative or bulk work an author does not want
interrupting the reader even in the foreground. Every other combination returns
`interaction_required`, which stays distinct from `interaction_declined`,
`interaction_timed_out`, and `cancelled`.

### Evidence

Prototype: `MangaCartaTests/WebKitPartitioningSpikeTests.swift` (isolation, identity, and the
relaunch phases), `MangaCartaTests/BrowserInteractionSpikeTests.swift` (criterion 8), and
`scripts/webkit-partitioning-spike.sh`, which drives the relaunch experiment as three separate
`xcodebuild test` runs — three separate app processes.

Measured on **iOS 17.5 (21F79)**, the runtime the design's gate names, on an iPhone 15 Pro
simulator, built with Xcode 26.6 against a 17.5 deployment target; every result below was also
reproduced on iOS 26.5 (23F77).

What the API did:

- `dataStoreForIdentifier:`, `removeDataStoreForIdentifier:` and `fetchAllDataStoreIdentifiers:`
  are declared `API_AVAILABLE(ios(17.0))` in the WebKit headers — checked in the SDK rather than
  taken from a documentation summary — so they are available on the 17.5 deployment target.
- **Isolation holds.** A `cf_clearance` cookie written into Source A's store is invisible from
  Source B's, both by `getAllCookies` and by `fetchDataRecords`, for two Sources on one origin —
  within a launch and across one. The same two Sources on `.default()` see each other completely,
  which is what the shipped service does today and is recorded as its own test so the reason for
  changing it does not become folklore.
- **Persistence holds.** Clearance written under one launch is recovered under the next, and the
  neighbouring Source still sees nothing.
- **`WKWebsiteDataStore(forIdentifier:)` vends the identical live object** for an identifier
  already open in the process. A same-process "close and reopen" therefore reads the live session,
  not the disk, and would pass even for a store that persists nothing. This is why the durability
  proof is a two-launch script and not a unit test.
- **A store no `WKWebView` was ever built against does not persist its cookies.** Writing through
  `WKHTTPCookieStore` and holding the store alive for six seconds still lost the cookie at process
  exit; constructing a web view against the store — with or without a navigation — made it durable.
- **The first read of a freshly opened store's cookie jar loses the race.** Immediately after
  opening, `getAllCookies` returned an empty jar twice in a row and then returned the cookie on a
  third read three seconds later; a three-second wait before the first read returned it
  immediately, as did any prior `fetchDataRecords`. There is no error and no partial state — just
  an empty jar. This cost this spike an hour and a wrong preliminary conclusion, and it is exactly
  the shape of bug that would ship as "Cloudflare keeps re-challenging me".
- **A store is not on disk until it is first used, and the listing is eventually consistent
  with that.** Constructing `WKWebsiteDataStore(forIdentifier:)` creates the object eagerly and
  its directory lazily, so `fetchAllDataStoreIdentifiers` does not list a store that has only
  been constructed. On an idle machine the directory lands before the next call and the
  distinction is invisible — which is how a test asserting it passed alone and failed inside the
  full test bundle, reading `false` with two identifiers listed and then `true` with three
  250 ms later. Awaiting one operation on the store (the same warm-up above) closed it in three
  consecutive full-bundle runs, because that round-trip is what materialises the session. This is
  related to the web-view rule above but not the same: a use materialises the *store*, while
  durable *cookies* additionally needed a `WKWebView`.
- **A navigation is not affected.** A page load issued immediately after opening the store *did*
  carry the restored cookie (`document.cookie` saw it). So the race is confined to the inspection
  API. The practical rule for the runtime is therefore narrow: drive the browser and let WebKit
  apply cookies; never gate behavior on an immediate jar read.
- Two cheaper ways to deliver a `cf-mitigated: challenge` header to the navigation-response
  delegate do **not** work, recorded so nobody retries them: a `WKURLSchemeHandler` response
  arrives downgraded to a bare `NSURLResponse` with every header stripped, and
  `loadSimulatedRequest` does not run the response-policy step at all. The criterion 8 prototype
  therefore serves the header from a loopback socket.

Reconsiderable if a future iOS changes any of the above; `scripts/webkit-partitioning-spike.sh`
takes a `SPIKE_DESTINATION` override so the experiment can be re-run against a new runtime.

### Alternatives rejected

- **One shared `.default()` store** — today's behavior. Rejected: it is measurably zero isolation
  between Sources, and §9 forbids it outright.
- **The design's named fallback: separate nonpersistent stores.** Rejected because it is no longer
  necessary. It would have been honest, and worth stating what it would have cost the reader: every
  Cloudflare challenge re-solved on every launch, for every protected Source, forever. That is a
  real product cost, and not paying it is the point of running this spike in Wave 1.
- **Persisting a Source-id-to-UUID mapping** instead of deriving the UUID. Rejected: it adds a file
  that can be lost or corrupted, and losing it loses every reader's clearance — the derivation has
  the same failure mode only if the namespace constant changes, which is a code change under
  review.
- **An `interaction` case per app state** (`background`, `foreground`, …). Rejected: an Extension
  cannot know the app's state, and letting an author assert it would let a Source talk its way into
  a sheet during a background refresh. The host supplies the context; the author supplies only a
  ceiling.

### Consequences

- S5's `host.browser.extract` builds on a per-Source store, not on `WebViewService`'s shared one.
  Three host rules come with it: construct the `WKWebView` for a Source's store before relying on
  its state; never treat an immediate cookie-jar read as authoritative; and never conclude a Source
  has no store from `fetchAllDataStoreIdentifiers` before that store has been used — an installer
  or data-removal screen that enumerates stores at launch is reading a listing that has not caught
  up yet, and would show a reader nothing.
- **`WebViewService` is not changed by this amendment.** It keeps its shared store for the compiled
  `WeebCentralSource` until that Source is ported (criterion 12), at which point the shared store's
  last user goes away. Until then the app deliberately holds both mechanisms.
- Clearance is now per Source. Two configured Sources on one site each solve their own challenge,
  which is more challenges than today for that specific case — the price of the isolation §9
  requires, and far cheaper than the fallback's per-launch cost.
- An explicit reader data-removal action maps onto `removeDataStoreForIdentifier:` per Source,
  which is a cleaner story than pruning one shared jar by domain.
- The UA stays host-owned and pinned, per §9. Nothing here changes that.

## Amendment 4 — repository identity is installer-minted, attestation is the maintainer's, and a typed declaration is a validated one (2026-09-11)

Amendments 1–3 stand unchanged. This amendment makes the decisions Phase 4 cannot start without:
it closes the Host API design's **evidence gates 3 and 4**, decides issue **#161**, and places
signing. The wire shapes, validation rules and operation semantics that follow from these decisions
are specified in the
[repository format design](../superpowers/specs/2026-09-11-repository-format-design.md); this
amendment owns the decisions and their reasons and does not restate the bytes.

Two of the questions here were the user's, not the design's — whether a reader-installed adult
Source is reachable at all, and whether signing is in v1 — because both are product calls with
App Review consequences. The design was written with both branches so the answer would slot in;
the answers, both the recommended branch, are recorded under "The user's answers" below.

### Context

Phase 3 proved that a Source is one engine script plus a validated declaration, and nothing else:
`HTMLSelectorThemeEngine` serves three differently configured declarations with no site in the
engine. Phase 4 has to get those bytes from a URL a reader types into `SourceLifecycleRegistry`,
and the design's "Identity lifecycle" section had already fixed the hardest constraint before any
installer existed: a repository *move* keeps its identity, a repository *replacement* gets a new
one, and Listings, pins and storage key on that identity. A URL cannot tell those two apart.

The other constraint is not technical. This project has **no moderation capacity** — no review
team, no approval queue, no one to notice an under-classified Source and act. A design that assumes
one is a design that will not be implemented, and the design's "Adult classification" section
wrote the word "approved" without being able to say who approves.

### Decisions

**1. The package format is a static index and nothing more.** One JSON document at an HTTPS URL;
per bundle, one engine script and one or more inline declaration records; per script, a SHA-256
the index states. The reader installs Sources, the installer fetches bundles, the maintainer
versions bundles with an integer. Every field beyond "a script and its declarations" was added
against a reason a reader can check, and the format design lists what was considered and left out.
The index carries its own integer `format`, separate from the per-declaration `hostAPI` range: one
versions the document the installer reads, the other the contract an engine runs against, and
giving them different grammars is deliberate so they cannot be mistaken for each other.

**2. Gate 3 — repository identity is minted by the installer, not derived from anything.** A
version-4 UUID at first add, persisted locally, bound to the URL it was added from, shown to the
reader as that URL. The qualified Source id is that UUID joined to the declaration's `localId`. A
URL change is a reader-confirmed re-point of an existing identity; a fork served from a new URL is
a new identity unless the reader chooses the re-point gesture instead. **The reader's gesture is
the only thing that distinguishes a move from a replacement, and in format 1 it is sufficient**;
the format design's "Repository identity" section tabulates each gesture. This keeps `QualifiedSourceID` stable — which is what Listings, pins,
`host.storage` and the per-Source WebKit store (Amendment 3) all depend on — with no signing
infrastructure and no key to lose.

The migration to key-based identity is named, not implied: when a signed format exists, the key
becomes an **attribute bound to the UUID** on the first verified index, never a replacement for it.
Rotation is a statement signed by the previous key; an index under a key that is neither bound nor
provably rotated is a replacement unless the reader says otherwise. Nothing keyed by the UUID
migrates when a key is bound or rotated. What a key adds that the gesture cannot provide is
recognising a move *without* a redirect or a reader's assertion.

**3. Gate 4 — the maintainer attests, the reader trusts, the host enforces what it can, and the
reader is the only reviewer there is.** Classification is attested by the repository maintainer by
serving the declaration; there is no other party. The trust decision is the reader's, made once, by
adding the repository URL, and the app treats every repository identically — **no "approved"
status exists in v1**, because no authority exists to grant it. The design's per-Listing rule is
the mechanical enforcement: a Listing an engine labels adult is adult regardless of its Source's
class, which makes honest per-Listing labelling the thing a maintainer is actually attesting.

What happens to an under-classified Source: **the reader elevates it locally**, and the effective
class is the maximum of the declared class and that elevation. The design's "Adult classification"
section said such a Source "is disabled pending corrected metadata"; that sentence assumed an
approving authority that observes the violation and there is none, so this amendment refines it:
the enforcement is the reader's elevation rather than disablement, the Source sits behind the
adult gate from that moment, and no update lowers the effective class, because lowering required
re-review and there is no reviewer. A disabled Source would punish the reader who noticed; a gated
one serves both the reader who wants it hidden and the reader who wants it labelled. "Approved"
becomes meaningful only with signing, where it can mean "signed by a key this app pins" — a
curated first-party index — and that is where it waits.

**4. #161 — a `SourceDeclaration` exists only as the validator's output.** `reinstall` keeps its
typed parameter; what changes is that the type's memberwise initialiser becomes inaccessible
outside `SourceDeclarationValidator`, so "must already have passed validation" stops being prose
and becomes a fact the compiler enforces. The installer takes the index's raw JSON, validates every
declaration from those bytes under the qualified id it minted, and hands the registry the result;
there is no other way to obtain one. A stored declaration is therefore raw JSON re-validated at
every launch, which is also the right behaviour on its own: an app update that tightens the
validator or retires a Host API version refuses the Source at launch with a sentence, instead of
running it under rules it was never checked against. Making `reinstall` itself take raw JSON was
the other option
and is rejected: the registry would then need the qualified id and the host's supported versions to
validate, which are the installer's inputs, and it would be parsing a document it does not own. The
type-level fix closes the same gap at the point where the value is born. The one test that
hand-builds a `SourceDeclaration` today moves to a JSON fixture. **#161 closes against this
amendment.**

**5. Signing is placed, whichever way the product answer goes.** A signed format changes exactly
three things: an index must verify under a key bound to the repository's UUID before it is parsed,
the script digest becomes something a signature vouches for rather than a maintainer's bare claim,
and automatic update application becomes defensible. An unsigned format asks the reader to trust
HTTPS, the host operator, the maintainer, and the domain staying in the maintainer's hands; what
bounds misplaced trust is the Host API's sandbox — declared origins, bounded storage, no
credentials — and the decision that **updates are offered, never applied automatically**, so a
hijacked domain reaches only a reader who taps Update. Signing protects updates, not first
install: with no curated key list, the first install is trust-on-first-use either way. Because
identity is minted rather than key-derived (decision 2), deferring costs no migration later: a key
binds to an identity that already exists. **Deferred to format 2 — the user's answer, recorded
below.**

**6. Retention is indefinite and bounded by quota, not by time; the quota number is not chosen
here.** Ordinary uninstall and repository removal retain the Source record, its storage, its WebKit
store, and every Listing and pin, until the reader's explicit erase. A time-based sweeper would need
a policy nobody has evidence for. The storage quota stays the provisional tunable already marked as
the open gate in code; the format design states the measurement that settles it and the decision
rule applied to that measurement, so that the number lands from the corpus rather than from feel.

**7. Updates are reader-confirmed and bundle-atomic; index refresh is foreground-only.** The
bundle is the unit because its Sources share one script and a Source must never run a script it
was not validated alongside. Refresh does not join the library's background pipeline, which polls
for chapters; polling for engines is a separate decision. An installed Source its repository stops
listing stays installed — the identity lifecycle already forbids deleting the reader's references on
absence, and a dropped listing cannot be told from a temporary one.

### The user's answers (2026-09-11)

- **Installed adult Sources: accepted, behind the existing gate.** The recommended option. A
  `mixed` or `adultOnly` declaration installs under the default-off "Show adult sources" gate that
  ADR-0022 deliberately retained, with a one-time acknowledgement at install. ADR-0022 Amendment 1
  records the decision and its App Review reasoning; the format design's "Adult Sources" section
  has the mechanics.
- **Signing: deferred to format 2.** The recommended option. Format 1 is unsigned; the script
  digest and the reserved key-binding slot are the seams format 2 uses; updates stay
  reader-confirmed until then. Decision 5 above is the reasoning.

### Alternatives rejected

- **Identity is the URL.** Rejected because the design already requires a move and a replacement
  to differ, and a URL cannot express the difference.
- **Identity is a maintainer-chosen id in the index.** Rejected because two maintainers can choose
  the same string, a fork inherits it, and the app cannot tell the fork from the original — the
  same reason `localId` alone is not identity.
- **Key-derived identity in v1.** Rejected because it makes signing a prerequisite for installing
  anything, puts a key-rotation format on the critical path of a phase that has none of the
  evidence to design one well, and turns a lost key into lost Listings. Minting first and binding
  a key later gets the same end state with nothing migrating.
- **An "approved repository" list, or any host-side review status.** Rejected because nobody can
  grant it. Naming it would make the design read as moderated when it is not.
- **Host-detected under-classification that disables the Source.** Rejected on the evidence of
  the first port: WeebCentral declares `none` and maps its adult tag to `erotica` per Listing,
  which is the intended use of per-Listing elevation, not a violation. One adult Listing from a
  `none` Source is normal; a machine cannot tell "occasionally labels adult" from "is an adult site
  with unlabelled Listings", and the second is the only real under-classification.
- **`reinstall` takes raw JSON.** Rejected for the reason in decision 4.
- **Automatic updates in an unsigned format.** Rejected because it removes the one point at which
  a reader stands between a hijacked domain and their device.
- **Semver for bundles.** Rejected because the installer asks one question of a version — "is it
  greater" — and a grammar with no consumer rots.
- **A time-bounded retention sweeper.** Rejected because no evidence supports any particular
  duration and the retained state per Source is quota-bounded already.

### Consequences

- S2 parses and validates the index and takes `SourceDeclaration`'s initialiser private to the
  validator; `ExtensionRuntimeTests` moves its hand-built declaration to a JSON fixture; a
  structural test in the style of `ManifestValidationCodeFreeTests` guards that no other file
  constructs one.
- S3 mints identity, persists the three records the format design names, wraps the registry's
  transitions, and re-validates stored declarations at launch. Phase 4 acceptance criterion 4 as
  worded — two repositories colliding on a qualified id — is unreachable by construction, since
  distinct UUIDs cannot collide; the test it implies is the within-index duplicate-`localId`
  rejection naming both occurrences, alongside criterion 3's proof that two repositories serving
  the same `localId` yield distinct qualified ids.
- S5's repositories screen carries the gestures this amendment makes load-bearing: "Add", "Change
  repository URL", "Remove", "Erase data", "Treat as adult", and a confirmed re-point on redirect.
  Each is an identity decision or a trust decision the reader is making, and the copy should say so.
- The Host API design's "Adult classification" sentence "the Source is disabled pending corrected
  metadata" is now read with decision 3: the enforcement is reader elevation and gating, not
  disablement. The design is not edited; this amendment is the record.
- Nothing about the Host API contract changes. Every gate closed here was an installer question.

## Amendment 5 — WeebCentral leaves the built-in set; the app ships the bridge alone (2026-09-21)

Amendments 1–4 stand unchanged. This amendment makes the cutover decision the Phase 4 plan said
"belongs in an ADR with the user's agreement, not in a PR body": the compiled `WeebCentralSource`
is removed, and the shipping app registers **MangaDex and nothing else** at launch. The user chose
this on 2026-09-21 between the two options recorded under "Alternatives" below.

### Context

Amendment 1 already said it: "the built-in set is the bridge and nothing more; everything a reader
adds, they add themselves." WeebCentral stayed compiled in for one reason this ADR's consequences
named — it was the **migration proving-ground**, the real Cloudflare-protected site that would
validate the Host API. That job is done. Phase 3 ported it to a declaration served by
`HTMLSelectorThemeEngine` and proved equivalence against captured fixtures; Phase 4's S6 (#192)
proved acceptance criterion 11 — WeebCentral **installed from a package** through
`ExtensionInstaller`, engine script and declaration loaded as package data, returning the same
search, detail, chapter and page results the port's fixtures pin.

So `main` now holds two copies of one Source. `CLAUDE.md`'s document-ownership rule is about
facts, but the failure it names — two copies that need updating by someone who remembers both
exist — applies to code exactly as well. The compiled source's five DOM-scraping strings are the
volatile part when the site redesigns; keeping them beside a declaration that encodes the same
selectors means the next redesign is fixed twice or, more likely, once.

### Decisions

**1. `WeebCentralSource` is deleted and `SourceRegistry.builtInSources()` returns MangaDex alone.**
WeebCentral becomes what every non-bridge Source is under Amendment 1: something a reader installs
from a repository they added by URL. The app does not know it exists.

**2. No bundled package and no default repository.** The app bundle carries no index, no engine
script and no declaration, so there is nothing the app "offers" in the sense guideline 4.7 turns
on (ADR-0022 Amendment 2). Amendment 4 chose "no default repository" for its own reasons and
ADR-0022 Amendment 2 built the App Review defence on that fact; a bundled first-party package would
be the app offering software again, would reopen that amendment, and would commit this project to
hosting and versioning a repository — a maintenance decision nobody has made. The engine script and
the WeebCentral declaration survive only as **test fixtures** (`MangaCartaTests/__Fixtures__/
weebcentral/repository-*`), which is where #192 already put them.

**3. The compiled id `weebcentral` is retired, and nothing stamped with it is migrated.** An
installed Source's id is `<repository-uuid>:weebcentral` (repository format design, "The qualified
Source id"); the two id spaces cannot collide by construction, so no Listing stamped `weebcentral`
can ever mean an installed Source. Data carrying the old id is **retained, not deleted** — the Host
API design's identity lifecycle forbids deleting the reader's references on absence, and that rule
does not get an exception for a Source the app itself withdrew. Such Listings are Listings of an
unregistered Source: unavailable, offered by the fulfillment picker as unavailable, and never
routed to another Source. A reader who later installs WeebCentral from a repository gets a **new
Listing** under the qualified id, joined to the same Work by ADR-0001's identity and ADR-0016's
bridge — not by any string rewrite. No migration code is written because there is nobody to migrate:
the app is pre-launch and the only data stamped `weebcentral` is the seeded simulator fixture,
which is re-seeded.

**4. #189 becomes load-bearing and is fixed in the cutover.** `SourceRegistry.source(for:)` today
routes *any* unregistered `sourceId` to the active source, a fallback written for legacy entries
whose `sourceId` is `nil` or `mangadex`. After this amendment a retained `weebcentral` Listing would
be routed to MangaDex and asked for a WeebCentral id. The fallback narrows to the legacy cases it
was written for; every other unregistered id is unavailable, which is decision 3 in code.

**5. ADR-0022's consequence "the public release ships MangaDex and WeebCentral" is superseded.**
ADR-0022 is not edited; it reserved its own Amendment 3 for an App Review reversal and this is not
one. Its gating machinery (`isNSFW`, `visibleSources(includeAdult:)`,
`enforceAdultGating(includeAdult:)`) stays, as it said it would, because installed Sources are
what it now gates.

### Alternatives rejected

- **A bundled package under a fixed app-owned repository UUID, installed at first launch.** The
  recommended option when the fork was put to the user, and rejected by them. It keeps a fresh
  install looking as it does today at the cost of decision 2's consequences: the app offers
  software again, ADR-0022 Amendment 2 reopens, a first-party repository needs an owner, and every
  `weebcentral` Listing needs a deterministic rewrite to the bundled qualified id — a migration
  written for a reader base of one simulator.
- **Keep both copies.** Rejected for the reason in Context; the Phase 4 plan allowed it only
  "briefly" and only if not silent.
- **Let the compiled Source keep the bare id `weebcentral` as an installed Source's id.** Rejected
  because the format design makes the installer's minting function the only producer of a
  qualified id and keeps the id spaces disjoint; a special case here is the collision the design
  was written to make impossible.

### Consequences

- **The cutover PR** — after #192 and #193 merge, as a follow-up on S6's terminal — deletes
  `Models/WeebCentralSource.swift`, the `WeebCentralSource` entry in `builtInSources()`, the
  compiled side of `WeebCentralPortTests` and `ExtensionPortHarness`, and any test that exists only
  to exercise the compiled Source; moves `HTMLSelectorThemeEngine`'s Swift-constant script and
  declaration out of the production target into the test fixtures (the engine *type* stays if
  anything in production still needs it; the constants do not); narrows the `source(for:)`
  fallback (#189, with a test that a retained `weebcentral` Listing is unavailable rather than
  routed); updates `CLAUDE.md`'s "Architecture" and "Current state" and any README line that says
  the app ships WeebCentral; and re-seeds the iPhone 17 Pro fixture so `works.json` carries no
  `weebcentral` Listing, or carries one deliberately, as an unavailable-Source test case.
- `WebViewService`'s shared persistent data store loses its last compiled consumer. Amendment 3's
  per-Source `WKWebsiteDataStore(forIdentifier:)` is now the only place a Cloudflare clearance
  lives; whether the shared store is removed is that amendment's question, not this one's.
- A fresh install of the public build has **one** Source. This is the empty-reader posture the
  ADR's Context described from the start, narrowed by Amendment 1 to keep the bridge.
- The reference repository that would let a reader install WeebCentral is **not this project's
  to host** under decision 2. Publishing one — from a separate repository, under its own name — is
  a product decision recorded nowhere yet, and it should not be inherited from this amendment.
