# Product analytics design

**Date:** 2026-11-09
**Status:** Draft for owner review, revised after coordinator review 2026-11-10, and revised 2026-11-11 for the
consent research and the owner's consent decision. **§5 is decided (owner, 2026-11-11): consent first, everywhere.
Nothing is collected or sent until the reader agrees on the first-launch card.** This replaces the owner's
2026-11-09 decision to collect unless the reader opts out. **Every open question was decided by the owner on 2026-11-12: all seven recommended answers approved**
(see "Owner decisions" at the end). Slice 1 may be built; slice 2 still waits on the legal review and the hosted
privacy policy (question 8).
**Evidence baseline:** `main` at `b57c356`.
**Slug:** `analytics`. **Handoff queue item:** 15.

This is product and regulatory research, not legal advice. **Before analytics ships, someone
qualified in EU/UK and US privacy law should review the consent behaviour (§5), the privacy-policy
facts (§10.3) and the label answers (§8).**

## Purpose and ownership

`PRODUCT.md:38-39` says the public product "may collect analytics by default to improve
recommendations and understand feature usage, with a clear Settings toggle to opt out". It also
lists what must be settled first: provider, event schema, retention, consent disclosure, regional
compliance, deletion/export controls, and whether historical events can train shared recommendation
models. On 2026-11-09 the owner chose analytics **on by default with a clear Settings opt-out**.
On 2026-11-11, after the consent research, the owner replaced that with **consent first, everywhere** (§5). Its
main purpose is **refining recommendations from reading data**, and its second is
feature usage.

This document owns *how* analytics is built and which data it carries. It answers every open item
in `PRODUCT.md:39`. Once the owner accepts it, the implementing PR shortens those lines to a link
here. Terms **Work**, **Listing**, **Listing key**, **Source** and **Fulfillment** are the
glossary's and are used without redefinition. The glossary (`docs/glossary.md:226`) already lists
"analytics" and "telemetry" as words to *avoid* for image-load reports. This feature keeps the two
apart: an image-load report goes to a Source's operator, and an analytics event goes to us. Slice 1
adds a glossary entry for **Analytics event**. The glossary owns terms, so the entry is not written
here.

## Goal

1. Send a small, closed set of **reading signals keyed by public catalogue ids** (MyAnimeList and
   AniList), plus **feature-usage counts**, to an endpoint the owner controls. The aim is to improve
   recommendations for everyone and to learn which features are used.
2. Collect **only after the reader agrees**, in every region, on a first-launch card that doesn't block
   the app, with a single Settings toggle. In the EU, EEA and UK the card asks; elsewhere it informs, and
   "OK" is the agreement (§5).
3. Keep **adult-classified titles and the reader's own files** out of analytics entirely, by
   construction rather than by convention (§3, §4).
4. Delete what was collected when the reader asks, and stop collecting the moment they turn it off (§7).

## Non-goals

- Crash reporting or diagnostics. MetricKit or a crash SDK is a separate decision.
- Advertising, attribution, IDFA, ATT, and any sharing with a data broker (§6).
- A server-side per-user recommendation profile. Per-user recommendations stay on the device (§9).
- Analytics on any surface not in the §2 table. A new event is a spec amendment, not a patch.
- Cross-device identity or linking the analytics id to a MyAnimeList account.
- A user-facing export file (§7.3 explains why, and what replaces it).
- Web or dashboard tooling beyond the query described in §9.

## Current code this builds on

Every reference below was opened at `b57c356`.

| What | Where | Why it matters |
|---|---|---|
| No analytics exists | `rg -i "analytics\|telemetry"` across the repo finds only `PRODUCT.md:38-39`, the glossary's *avoid* note (`docs/glossary.md:226`), handoff text, a skill doc and Public Suffix List entries | Greenfield. Nothing to migrate. |
| Chapter-completion sink | `HistoryStore.swift:116` (`ChapterCompleted`), fired at `HistoryStore.swift:194-200` only when an entry goes incomplete → complete **and** `MALChapterProgress.map` yields an integer (`MALReadingProgress.swift:18-29`) | The one existing "a chapter was finished" seam. It is synchronous and network-free by contract (`AppComposition.swift:311-316`). |
| Completion payload | `ChapterCompletion` (`MALReadingProgress.swift:10-16`): `manga`, `chapter`, `workID`, `progress`, `completedAt` | Carries the `Manga` (rating, source) and the `WorkID` (external ids) the eligibility check needs. |
| Completion wiring | `AppComposition.swift:313-316` passes one closure to `HistoryStore` that forwards to `MALProgressCoordinator` | Slice 1 fans this closure out to the recorder as well. |
| Manual "Mark read" | `HistoryStore.markRead(manga:chapter:)` (`HistoryStore.swift:299`) does not call the sink | A manual mark is not reading, so it emits no `chapter_completed` here either, matching MAL sync. |
| Save | `LibraryStore.toggle(_:)` (`LibraryStore.swift:166-186`) mints a Work and inserts a `LibraryItem` | A `Manga` is in hand, so eligibility can be checked. |
| Unsave | `LibraryStore.items` `didSet` → `reportWorksThatLeft` (`LibraryStore.swift:82`, `:341-355`) → `configureWorkLeftLibrary` handler (`:336`), at Work granularity across every removal path | The unsave event hooks here, so all removal paths are covered. Only a `WorkID` is in hand, which drives the ledger in §11.4. |
| Feedback | `RecommendationEngine.markNotInterested` / `markMoreLikeThis` (`RecommendationEngine.swift:145-157`), reached from the For You card context menu (`RecommendationRail.swift:32-39`, `HomeView.swift:160-161`) | Explicit taste signals. |
| For You card tap | `NavigationLink` per card (`RecommendationRail.swift:22`) | Needs an `onOpen` hook to log a tap with its rank. |
| More Like This and Related rails | Today `MangaDetailView.swift:558-564` renders `MangaRail(items:)` of resolved `Manga`. MAL-hub slice 3 replaces it with MAL-native `MALDiscoveryCandidate` rails (slice 1, the projection, is built), so the hook is specified against the candidate: `to` is the candidate's MAL id. | Needs an optional `onOpen` hook. Candidates come from the shared MAL detail cache (`docs/superpowers/specs/2026-11-09-mal-hub-recommendations-design.md`). |
| On-device recommender | `CandidateProvider` protocol (`CandidateProvider.swift:21-26`), `TagCandidateProvider`, and `TasteProfile.build` with the ×2 "more like this" boost at `TasteProfile.swift:116` | §9: what aggregate data can tune, and where a new provider slots in. |
| Public catalogue ids | `ExternalIDs { mal: Int?, anilist: Int? }` on every `Work` (`Work.swift:44-55`, `:112-124`); `Manga.malId` (`MangaModels.swift:26`) | The only ids analytics ever sends. |
| Adult gate | `AdultContentFilter.admits(rating:sourceDeclaresAdultTitles:showAdultContent:)` (`AdultContentFilter.swift:13-20`); `AdultClassification` `none/mixed/adultOnly` (`SourceDeclaration.swift:98-102`); `MangaSource.isNSFW` / `declaresAdultTitles` (`MangaSource.swift:24-27`); `Manga.contentRating` (`MangaModels.swift:113`); `TagVocabularyStore.isAdult(_:)` (`TagVocabularyStore.swift:65`) | §3 reuses this predicate with the switch pinned off. |
| Local Source | `LocalSource.sourceID = "local"` (`LocalSource.swift:4`), `isBrowsable false` (`:8`); ADR-0025 | §4. |
| Per-Listing participation precedent | `MALProgressCoordinator` takes `listingParticipates: (ListingKey) -> Bool` (`MALProgressCoordinator.swift:87`, `:116`) and checks it first (`:135`) | Same pattern: the composition root decides which Listings are eligible. |
| Privacy manifest | `PrivacyInfo.xcprivacy` declares Name, User ID and Product Interaction (linked, App Functionality, for MAL; `:54`) and Performance Data (not linked, for image-load reports; `:69`). `NSPrivacyTracking` is false (`:80`) and there are no tracking domains | §8 adds one type and one purpose. |
| Label research precedent | `docs/superpowers/research/2026-09-11-issue-149-mal-privacy-label.md`; `docs/app-store/submission-copy.md` §5 | Apple's definition of collection, and the fact that "a data type can appear only once". |
| Disclosure precedent | ADR-0003 Amendments 9–10: image-load reports are declared on the label and disclosed in the install sheet, with "no switch" | The contrast case. Analytics *does* get a switch, because it goes to us and serves us. |
| Settings pattern | `@AppStorage(UpdateNotifier.notificationsEnabledKey)` (`SettingsView.swift:14`); the Updates section card with a `Toggle` (`SettingsView.swift:112-138`); About (`:236-246`) | The new Privacy section copies this card. |
| Scene activation | `.onChange(of: scenePhase)` (`MangaCartaApp.swift:266`) | Upload trigger in slice 2. |

## 1. Provider and backend (question 1)

Three options were compared using the vendors' own pages, read 2026-11-09.

**A. TelemetryDeck (privacy-focused SDK).**
- Package `https://github.com/TelemetryDeck/SwiftSDK`, product `TelemetryDeck`. Set up with
  `TelemetryDeck.initialize(config: .init(appID:))` and send with
  `TelemetryDeck.signal(_:parameters:)`. Parameter values are strings
  ([Swift setup](https://telemetrydeck.com/docs/guides/swift-setup/)).
- The SDK salts and hashes the user id on the device, and the server salts and hashes it again. The
  resulting id "stays the same for one app installation". Data is "stored exclusively on European
  soil", on Hetzner in Falkenstein and Helsinki ([FAQ](https://telemetrydeck.com/faq/);
  [pricing update, July 2026](https://telemetrydeck.com/blog/pricing-update-2026/): "exclusively on
  German providers").
- New accounts get 50,000 events a month free from 1 July 2026. Paid prices sit behind a calculator
  and were not confirmed ([pricing update](https://telemetrydeck.com/blog/pricing-update-2026/)).
- **Per-user deletion is not possible.** "An end-user cannot ask us to delete their events". Only a
  whole month or the whole organisation can be deleted ([FAQ](https://telemetrydeck.com/faq/)).
  Retention means data "gets unloaded" to cold storage, not deleted, and no period is published.
- Raw rows are reachable through a TQL Scan query
  ([query API](https://telemetrydeck.com/docs/api/api-run-query/)). There is no documented
  raw-signal file export.
- Its label guidance is: Identifiers › Device ID, not linked, not tracking; Usage Data › Product
  Interaction, not linked, purpose Analytics
  ([App privacy](https://telemetrydeck.com/docs/articles/apple-app-privacy/)).
- This would be the app's first third-party runtime dependency (`PRODUCT.md:42`). The owner has
  allowed one for RAR, so this is acceptable if justified.

**B. Self-hosted ingest endpoint.** One HTTPS endpoint that accepts a batch of events, one table,
and a scheduled purge. A Cloudflare Worker with D1 is the cheapest concrete shape. Workers' free
plan allows 100,000 requests a day, and the paid plan is $5 a month with 10 million requests
included. D1's free plan allows 100,000 rows written a day and 5 GB of storage
([Workers pricing](https://developers.cloudflare.com/workers/platform/pricing/)). Batching means one
request per upload, not per event, so a few thousand readers fit in the free tier. The operational
cost is one small deploy, one secret-free endpoint (so abuse is a risk, see §13), and owning the
retention purge. This design does not rely on per-IP limits: Cloudflare Workers may run many
short-lived isolates, so an in-memory counter is ineffective; validation, batch-size limits, schema
rejection and the k-thresholds in §13 are the abuse controls. Cloudflare is a US company, which the
privacy policy must name. Where the data lives is a configuration detail the implementer must
confirm, not a claim made here.

**C. Apple App Analytics only.** It gives downloads, sessions, retention and crashes, but only "from
users who have agreed to share their diagnostics and usage information with app developers", and it
has no custom in-app events ([App Analytics](https://developer.apple.com/app-store/app-analytics/)).
**It cannot carry a single reading signal, so it fails the primary purpose.** It stays on regardless,
because it costs nothing.

**Pick: B, self-hosted**, behind an `AnalyticsTransport` protocol so A can replace it without
touching the recorder. The primary purpose decides it:

- Recommendations need the **raw per-install event rows** to compute co-occurrence (§9). B returns
  them from one SQL query. A puts them behind an asynchronous Scan query on data whose retention is
  unpublished.
- "Delete my data" (§7) is only real with B: `DELETE … WHERE install = ?`. With A, the honest answer
  to an erasure request is that it cannot be done. TelemetryDeck's position is that the data is
  anonymous. A stable per-install pseudonym attached to reading history is still pseudonymous data
  under GDPR Recital 26, so this spec does not rely on that position.
- B adds no SDK, so the app sends exactly the §2 envelope and nothing more. A's SDK adds its own
  default parameters, which would then have to be audited and disclosed.

If the owner would rather not run a server, A is a reasonable runner-up for feature usage. It is a
worse fit for recommendations and for deletion. See Open question 1.

## 2. What is collected, exactly (question 2)

### 2.1 Envelope — on every event

| Field | Type | Example | Why |
|---|---|---|---|
| `v` | Int | `1` | Schema version. The server rejects versions it does not know. |
| `install` | String (UUID v4) | `"5F0C…"` | A random analytics id (§6). Not an IDFA, not an IDFV, not a MAL id. |
| `day` | String, UTC `yyyy-MM-dd` | `"2026-11-09"` | Day granularity only. No time of day, so a reading sequence cannot be lined up with anything else. |
| `app` | String | `"1.0 (42)"` | `CFBundleShortVersionString (CFBundleVersion)`, used to read feature use by release. |
| `name` | String, closed set | `"work_saved"` | Taken from the §2.2 and §2.3 tables. |

There is **no** device model, OS version, locale, time zone, storefront, IP address (the server must
not store it, §7), screen size or session id.

### 2.2 Recommendation events

`ids` is `{ "mal": Int?, "anilist": Int? }`, taken from the Work's `ExternalIDs` (`Work.swift:44`),
with `Manga.malId` as a fallback. **An event whose `ids` would be empty is dropped, not sent with a
title.** Each event also passes the eligibility checks in §3 and §4 first.

| `name` | Extra fields | Hook | Signal |
|---|---|---|---|
| `work_saved` | `ids` | `LibraryStore.toggle` add branch (`LibraryStore.swift:171-185`) | Explicit interest |
| `work_unsaved` | `ids` | `workLeftLibrary` (`LibraryStore.swift:336-355`), only for a Work in the sent ledger (§11.4) | Interest withdrawn |
| `chapter_completed` | `ids`, `progress: Int` (integer chapter, from `ChapterCompletion.progress`) | completion sink (`AppComposition.swift:313-316`) | Depth of reading: a reader who stops after chapter 1 versus one who reads through |
| `rec_not_interested` | `ids` | `RecommendationEngine.markNotInterested` (`:145`) | Negative label for a For You candidate |
| `rec_more_like_this` | `ids` | `RecommendationEngine.markMoreLikeThis` (`:153`) | Positive label |
| `for_you_opened` | `ids`, `rank: Int` (0-based position), `reason: String` (closed set: the tag-name reason is replaced by its **kind**, `"tag"` or `"explore"`) | `RecommendationRail` card `onOpen` | Click-through by rank, for weight tuning |
| `for_you_shown` | `count: Int` | when `railState` becomes `.ready`, at most once per UTC day | The denominator for click-through. It carries no ids. |
| `mlt_opened` | `from: ids` (the detail page's Work), `to: ids` (the opened `MALDiscoveryCandidate`'s MAL id) | detail-page MAL-native More Like This candidate `onOpen` | Whether MAL's "readers also liked" lands for our readers |

**Why ids, not titles or Listing ids.** MAL and AniList ids are public catalogue facts that name a
series, not a site. A MangaDex UUID or WeebCentral slug would reveal which installed Source the reader
uses, and some Sources are sensitive in themselves (ADR-0022). Titles are free text, and free text is
how personal data gets in.

### 2.3 Feature-usage events

These carry **no catalogue id**.

| `name` | Extra fields | Hook |
|---|---|---|
| `app_active` | — | first `scenePhase == .active` of each UTC day |
| `reader_opened` | `mode: "ltr" \| "rtl" \| "vertical"` | `ReaderView` appears, at most once per chapter open |
| `search_used` | — (never the query) | `SearchViewModel` submits a non-empty query |
| `local_import_finished` | `files: "1" \| "2-9" \| "10+"` (bucket) | `LocalImportViewModel` completes a batch |
| `source_installed` | `adult: "none" \| "mixed" \| "adultOnly"` — never the Source id or the repository URL | `ExtensionInstaller` install success |
| `setting_changed` | `key`, from the closed set `notifications`, `mal_sync`, `show_adult`, `reading_mode_default`, plus `on: Bool` or `value` from that setting's enum | the Settings bindings |
| `analytics_enabled` | — | the toggle turns on. Sent *after* consent, so a reader who never opts in sends nothing. There is no `analytics_disabled` event: once the toggle is off, nothing is sent (§7.2). |

`source_installed` reveals only the adult *class*, which is aggregate and useful for knowing how many
readers the gate affects. Whether to collect it at all is Open question 6.

### 2.4 Never collected

Titles, alternative titles, descriptions or any other free text. Search queries. File names, folder
names and anything else about a `local` item (§4). Source ids, Listing ids, chapter ids, page
numbers, image URLs and repository URLs. Exact timestamps. MAL username, MAL user id and tokens.
IDFA and IDFV. Contacts, location and photos. Any event about an adult-classified title (§3).

### 2.5 Typed so that free text cannot get in

`AnalyticsEvent` is a Swift `enum` whose associated values are `Int`, `CatalogueIDs`, `Bool` or
small `enum`s, with **no `String` payload** anywhere. The wire encoder is the only place strings
appear, and every one of them comes from an enum's `rawValue`. A reviewer checking for "no titles"
checks one type, not every call site. Test: `AnalyticsEventTests.testWireFormHasOnlyClosedStrings`
(AC 3).

## 3. Adult content (question 3)

**Recommendation: exclude adult-classified Works and Sources from analytics entirely, whatever the
"Show adult content" switch says.** What someone reads among adult titles is sensitive, and this
catalogue is not worth that risk. ADR-0022 already treats adult content as opt-in at every layer.

A Work is **ineligible** if any of the following holds, checked at event time against the `Manga`
in hand:

1. `!AdultContentFilter.admits(rating: manga.contentRating, sourceDeclaresAdultTitles:
   source.declaresAdultTitles, showAdultContent: false)`. This is the existing discovery predicate
   (`AdultContentFilter.swift:16-20`) with the switch **pinned off**, so an `erotica` or
   `pornographic` title is excluded, and so is an *unrated* title from a `mixed` Source. That keeps
   ADR-0022 Amendment 6's "missing means unknown, never safe".
2. `source.isNSFW`. This covers an `adultOnly` Source and a reader's "Treat as adult" elevation.
3. Any of the Work's snapshot genres or tags is adult according to `TagVocabularyStore.isAdult`
   (`TagVocabularyStore.swift:65`). This catches an AniList- or MAL-adult series reached through a
   Listing whose own rating is missing.
4. The Source cannot be found in the registry (uninstalled or disabled). **Unknown means excluded.**

This is one pure function, `AnalyticsEligibility.admits(manga:source:work:vocabulary:)`, so the
choice is made in one place (ADR-0022 Amendment 6, decision 5). `mlt_opened` checks `from` and the
candidate's `resolvedListing` through the same eligibility predicate. An unresolved candidate is
ineligible: it has no Source, and §3 rule 4 says unknown means excluded. If either side fails, the
whole event is dropped. The home `RecommendationRail` hook is unchanged and still receives
`(Manga, Int)`.

Two options were rejected:

- **Follow the reader's switch.** That would turn a display preference into consent to share
  sensitive reading data. They are different questions.
- **Send adult events with ids hashed.** MAL ids form a small public space, so a hash of one is
  reversible by enumeration.

`work_unsaved` has no `Manga` in hand. It is sent only for a Work that the ledger (§11.4) recorded
as sent on save, so it can never be the first event to reveal a title.

## 4. Local library (question 4)

**Recommendation: exclude.** Imports are the reader's own files (ADR-0025). A Work is ineligible
when **any** of its Listings is `local` (`LocalSource.sourceID`), not only when the event's own
Listing is. The local-library-matching spec drafted today
(`2026-11-09-local-library-matching-design.md`) can link a local Work to MAL, and once that happens a
MangaDex read of the same Work would otherwise announce that the reader owns those files.

The cost is lost signal on series the reader both owns and streams. That is a small loss and an easy
rule to explain: "your files never inform analytics". `local_import_finished` is a feature count with
a bucketed file count and nothing about the content. Test:
`AnalyticsEligibilityTests.testWorkWithAnyLocalListingIsIneligible` (AC 5).

## 5. Consent and regions (question 5)

### 5.1 What the law says

The research is `docs/superpowers/research/2026-11-09-unrar-licence-and-analytics-consent.md`, part B. It is product research, not legal advice; the review in open question 8
still applies. Its findings, by region:

- **Everywhere: Apple's App Review Guideline 5.1.1(ii)** says apps that collect usage data must secure the
  user's consent for the collection, even if the data is considered anonymous. It doesn't depend on region.
  That is the finding that decides §5.2: a design that sends anything before the reader acts is the risk.
- **EU/EEA: opt-in, confirmed.** Storing the install id and sending events derived from on-device activity
  both fall within ePrivacy Art. 5(3) (EDPB Guidelines 2/2023 ¶33, ¶44, ¶63). No "strictly necessary" route
  fits. **CNIL's audience-measurement exemption is unavailable:** it needs an identifier that lives at most
  13 months and "anonymous statistics only", and §6's id is never rotated and §2.2 builds per-install
  histories.
- **UK: opt-in, confirmed.** The Data (Use and Access) Act 2025's statistical-purposes exception doesn't
  allow keeping individual-level rows after aggregation, and §7.1 keeps raw events for 12 months. So **the
  ICO's consent-free route is unavailable** too, even for §2.3's counts.
- **Switzerland: corrected.** Neither the revFADP nor TCA Art. 45c requires opt-in here. Swiss law requires
  information plus a right to refuse, and explicit consent only for sensitive data or "high-risk
  profiling". Whether reading histories amount to high-risk profiling **needs a lawyer**.
- **US: confirmed in substance.** First-party analytics isn't "sale" or "sharing" under the CCPA/CPRA, and a
  small developer is very unlikely to meet its thresholds. CalOPPA's privacy-policy duty may still apply,
  and Apple requires a policy regardless.
- **Elsewhere** (Brazil's LGPD, Korea, Japan and others) was not researched. Consent first everywhere
  covers them by construction.

### 5.2 Behaviour: consent first, everywhere

**Decided by the owner, 2026-11-11.** Nothing is recorded, buffered or sent, and no install id is minted,
until the reader agrees on the first-launch card (§10.1). Undecided means off, in every region. Region
changes only how the card asks:

| Region | Before the reader chooses | First-launch card (§10.1) |
|---|---|---|
| EU 27, Iceland, Liechtenstein, Norway, United Kingdom | **Off** | Asks: "Share" / "Not now", given equal weight |
| Everywhere else, **including Switzerland** | **Off** | Informs, then asks for acknowledgement: "OK" / "Turn off". "OK" is the agreement |
| Region unknown | **Off** | As for the EU row (fail closed) |

- **Switzerland moves to the second row**, per the research's correction (TCA 45c is information plus a
  right to refuse). **Unless** the review in open question 8 finds that reading histories are high-risk
  profiling, in which case it moves back to the first row. That is a one-line change to
  `AnalyticsRegionPolicy`'s table.
- **Nothing is buffered before agreement.** The research floated recording locally until the card is
  answered, then sending on "OK". This design doesn't: events from before consent would be sent with
  consent they never had. The first event is the first hook after agreement.
- **One toggle, no UK split.** A split (counts on by default) needed the ICO's exception, which §5.1 rules
  out, and consent first everywhere makes it moot.

### 5.3 How the app learns the region

`await Storefront.current?.countryCode` (StoreKit 2, iOS 15+; "the three-letter code that represents
the country or region associated with the App Store storefront",
[Apple](https://developer.apple.com/documentation/storekit/storefront/countrycode)). If the storefront
is `nil` (no App Store account, or a simulator), the region is unknown and gets the EU row's card, whatever
the locale says. Otherwise, `Locale.current.region?.identifier` (alpha-2) may only make the result stricter:
a consent-region locale with a non-consent storefront still requires opt-in, but a non-consent locale
can never remove the requirement from a consent storefront. The locale is not a location signal (it depends on
the app's shipped localizations), so it can only ever make the card ask rather than inform. Since nothing is
collected undecided anywhere, the region now decides only the card's wording, never whether data flows. **Neither value is sent**
(§2.1). `AnalyticsRegionPolicy.asksForConsent(storefrontCountryCode:localeRegionCode:) -> Bool` is
pure and takes either alpha-2 or alpha-3 codes.

**Re-evaluation.** The region is read on every launch. If the reader has **never chosen**, the card they
see follows the current region. An explicit choice is never overridden by a region change. Test:
`AnalyticsConsentTests.testExplicitChoiceSurvivesRegionChange` (AC 2).

## 6. Identity (question 6)

- **A random UUID v4, minted on the first event once collection is allowed**, and stored in
  `Application Support/analytics/install.json`. It is deliberately **not** in the Keychain, which
  survives deleting the app. Deleting the app should end the identity.
- **It is reset when the reader opts out**: the id and the buffer are deleted, and slice 2 also sends
  a deletion request (§7.2). Opting back in mints a fresh id. "Reset analytics ID" in Settings does
  the same without changing consent.
- **No IDFA, and AdSupport is not linked. No IDFV.** Apple allows IDFV for analytics across one
  vendor's apps, but this app has no sibling apps and a random id is simpler to reset.
- **No ATT prompt.** Apple defines tracking as linking data from this app "with user or device data
  collected from other companies' apps, websites, or offline properties for targeted advertising or
  advertising measurement purposes", or sharing it with data brokers
  ([User privacy and data use](https://developer.apple.com/app-store/user-privacy-and-data-use/);
  [App privacy details](https://developer.apple.com/app-store/app-privacy-details/)). This design does
  neither, and it commits to never joining the analytics id with the MAL account id. So
  `NSPrivacyTracking` stays `false` and `NSPrivacyTrackingDomains` stays empty. **This holds only
  while the data is never used for ads and never sold.** The privacy policy states both (§10.3).
- **No automatic rotation.** Co-occurrence (§9) needs a history longer than a rotation window, and
  the 12-month purge (§7.1) bounds how long any id's history lasts. This is also why neither the CNIL nor
  the ICO consent-free stream is available (§5.1). A consent-free stream would need a separate, rotating or
  absent id, and consent first everywhere means none is needed.
- **Minted only after agreement** (§5.2), so a reader who never answers the card never has an id.

## 7. Retention, deletion, export (question 7)

### 7.1 Retention

- **On the device:** at most 500 events in the buffer, oldest dropped first. Events are deleted once
  the server accepts them.
- **Raw events on the server: 12 months, rolling**, purged by a daily scheduled job. Twelve months
  covers seasonal reading and a full year of co-occurrence. Open question 4.
- **Derived aggregates** (the §9 pair-count table) are kept for as long as they are useful. That is
  defensible only because each published pair needs at least *k* = 20 distinct installs and the
  table carries no install ids.
- **The server never stores the request IP or the user agent.** The Worker reads only the body. Slice
  2 must disable Cloudflare Workers request logging, Workers Logs/observability and Logpush; otherwise
  Cloudflare's own logs may retain IP addresses and this promise would be false.

### 7.2 Deletion, and what opting out does

| Reader action | On the device | On the server (slice 2) |
|---|---|---|
| Turns analytics off | Recording stops immediately. Buffer deleted. Install id deleted. | `DELETE /v1/installs/{id}` is queued and sent best-effort (retried on the next launches until it succeeds or 30 days pass). It removes **every raw event** for that id. |
| "Reset analytics ID" | Buffer and id deleted. A new id is minted on the next event. | Same delete for the old id. |
| "Delete my analytics data" | Same as turning off, then re-asks nothing | Same delete. |
| Deletes the app | Everything local is gone | Nothing is sent. Those events age out at 12 months. The policy says so and gives an email route quoting the id, which is shown in Settings so it can be copied (§10.2). |

Derived aggregates are **not** recomputed when one install is deleted. An install's contribution to a
k ≥ 20 pair count is not about a person. The policy must state this (§10.3, Open question 4).

The delete endpoint is authorised by possession of the id. Ids are 122-bit random values that only the
device knows (§13).

### 7.3 Export

**No in-app export file.** The device already holds a fuller copy of everything that is sent: the
Library, History and feedback. The events are a strict, reduced projection of that. Settings instead
shows "**What is sent**", a list of the events currently buffered in plain language (§10.2), which
answers the transparency need. A formal access request (GDPR Art. 15) is answered by email, using a
server query by id. Open question 5.

## 8. App Store privacy label and `PrivacyInfo.xcprivacy` (question 8)

These change in **slice 2**, the first slice that sends anything. Slice 1 sends nothing and must not
change the label.

| Item | Today | After slice 2 | Why |
|---|---|---|---|
| Identifiers › **Device ID** | not declared | **add**: Linked **Yes**, Tracking **No**, Purpose **Analytics** | Apple's Device ID is "the device's advertising identifier, or other device-level ID", and a random install id is the conservative fit. **Linked: Yes**, corrected by the research (part B5): Apple treats anything that is personal data under privacy law as linked, and a persistent install id with a usage history is very likely personal data under the GDPR. TelemetryDeck's "not linked" guidance doesn't survive that. |
| Usage Data › **Product Interaction** | Linked Yes, Tracking No, Purpose App Functionality (`PrivacyInfo.xcprivacy:54`) | **add purpose Analytics** to the same entry. Linked stays Yes. | A data type can appear only once (`docs/app-store/submission-copy.md` §5). The MAL use keeps it linked, and the stricter answer covers analytics. |
| Diagnostics › Performance Data | not linked, App Functionality (`:69`) | unchanged | Image-load reports only. |
| Name, User ID | MAL only | unchanged | The analytics id is not a User ID. |
| `NSPrivacyTracking` / `NSPrivacyTrackingDomains` | false / empty | unchanged | §6. The ingest host is not a tracking domain. |
| `NSPrivacyAccessedAPITypes` | FileTimestamp C617.1, UserDefaults CA92.1 | unchanged | Consent flags live in UserDefaults (already declared). The buffer is a file the app writes and reads. StoreKit's `Storefront` is not a required-reason API. |
| App Store Connect "Data Used to Track You" | none | none | §6 |

The manifest diff in slice 2 is one new `<dict>` (Device ID) and one added `<string>`
(`NSPrivacyCollectedDataTypePurposeAnalytics`) in the Product Interaction entry, each with a comment
linking here, as the existing entries do. The same PR updates `docs/app-store/submission-copy.md` §5,
which owns the label answers, and `PRODUCT.md:38-39`.

## 9. How the data actually improves recommendations (question 9)

To be plain about what changes: **per-user recommendations already run on the device and do not need
this data.** For You builds a `TasteProfile` from local history and asks `TagCandidateProvider` for
tag feeds (`CandidateProvider.swift:28-60`). More Like This uses MAL's own recommendations, which come
from millions of MAL users (`docs/superpowers/specs/2026-07-21-more-like-this-design.md`). Analytics
cannot beat MAL's crowd signal until MangaCarta has a crowd of its own.

What the §2 schema can support:

1. **Tuning the hand-set weights.** With per-install sequences of `work_saved`, `chapter_completed`
   and `rec_*`, an offline replay can score `TasteProfile`'s constants: the ×2 "more like this"
   boost (`TasteProfile.swift:116`), group weights, exploration share. Hide each install's last save,
   rebuild a profile from what came before, and measure whether the held-out title ranks higher.
   `for_you_opened` with `rank`, against `for_you_shown`, gives click-through by position and by
   reason kind. **Buildable from this schema.** The analysis runs off-device, and any result arrives
   as a code change to the constants, reviewed as one.
2. **"Readers who saved X also saved Y".** Count pairs of MAL ids that co-occur within one install's
   saves and completions. Publish a static `cooccurrence-v1.json` (MAL id → top-N MAL ids with
   counts) **only for pairs with at least 20 distinct installs**. A new `CoOccurrenceCandidateProvider`
   behind the existing `CandidateProvider` seam (`CandidateProvider.swift:21`) maps the reader's own
   Works to candidates on the device, and MAL ids become openable titles through the existing reverse
   resolution. **Buildable from this schema, but useful only at scale.** With a few hundred readers,
   almost no pair clears k = 20, and the provider would rightly return nothing. Slice 3 ships the
   provider and its threshold, and the provider stays dark until the table has content.
3. **Checking More Like This.** `mlt_opened` per `from` shows whether MAL's suggestions land for our
   readers. That is a check, not a model.

What would need more than this schema:

- Per-user server-side recommendations need a server-side profile per install. This spec does not
  build one (§ Non-goals).
- Learned models (embeddings, matrix factorisation) need dwell and impression data, which §2 omits on
  purpose, and the scale point from item 2 applies even more strongly.
- Anything "readers like you" in real time needs a request path from the app to the server at
  recommendation time. Slice 3's static file avoids that.

`PRODUCT.md:39` asks **whether historical events can train shared recommendation models.** The
recommendation is **yes, but only as k-thresholded aggregates (item 2) and offline weight tuning
(item 1). No per-install model, and nothing sold or shared.** The policy says so. Open question 4.

## 10. Disclosure UX (question 10)

### 10.1 First-launch notice — not a wall

A card shown inline at the top of Home on the first launch after analytics ships. **Nothing is collected
while it is unanswered** (§5.2), so it stays, on each launch, until either button is tapped. It still never
blocks navigation. The same card
covers existing readers, for whom "first launch" means the first launch on this version. It follows
the existing inline-notice pattern (`ForYouBasisNotice`): an `Ink.surface` card with a hairline, as
in Settings (`SettingsView.swift:134-135`), which never blocks navigation. It is shown once. Either
button dismisses it, and the choice is recorded.

Outside the EU, EEA and UK (the second row of §5.2):

> **Help improve recommendations**
> If you tap OK, MangaCarta shares which titles you save and finish — by their MyAnimeList and AniList numbers, never
> their names — plus which features you use. Adult titles and your own files are never included.
> It isn't linked to your name or your accounts. You can turn this off any time in Settings.
> [ OK ]  [ Turn off ]

In the EU, EEA and UK, and when the region is unknown:

> **Help improve recommendations?**
> *(the same body text, with "If you tap OK, MangaCarta shares" replaced by "MangaCarta can share", and "You can change this any time in Settings")*
> [ Share ]  [ Not now ]

The two buttons are the same size and style. A "Share" in vermilion beside a grey "Not now" would be
a dark pattern regulators name, so neither gets the vermilion seal treatment: **DESIGN.md** reserves
vermilion for meaningful state and action, and here neither button is more meaningful than the
other.

### 10.2 Settings — a new "Privacy" section

The section sits between the MAL section and About (`SettingsView.swift:234-236`). It is a card in
the Updates pattern.

- Header: `InkSectionHeader("Privacy", eyebrow: "Data")`.
- `Toggle("Share usage to improve recommendations", isOn: …)`.
- Footnote (secondary ink): "Saved and finished titles, by MyAnimeList and AniList number, and which
  features you use. Never names, searches, your files, or adult titles."
- `NavigationLink("What is sent")` opens a list of the buffered events in plain language, for example
  "Saved a title (MAL 21)" and "Opened the reader (right to left)", with the analytics id shown below
  it in a monospaced, selectable row.
- `Button("Reset analytics ID")`.
- `Button("Delete my analytics data", role: .destructive)`, with a confirmation dialog.
- `Link("Privacy policy", destination: …)`. The URL is owed by the owner (§10.3).

### 10.3 Privacy-policy facts the owner must publish

The policy itself does not exist yet (`docs/superpowers/research/2026-09-11-issue-149-mal-privacy-label.md`,
"Still owed"). When written, it must state:

1. Who the controller is, and a contact email.
2. That analytics is collected only after the reader agrees, in every region: asked in the EU, EEA and
   UK, and informed with "OK" / "Turn off" elsewhere. How to turn it off later, which withdraws consent
   (Guideline 5.1.1(i)).
3. The exact §2 fields, and the §2.4 list of what is never collected, including the adult and local
   exclusions.
4. Where the data goes (the provider and its country), and that no IP address is stored; this is
   true only with Cloudflare Workers request logging, Workers Logs/observability and Logpush disabled.
5. The purposes: improving recommendations, both offline weight tuning and aggregated co-occurrence,
   and understanding feature use. **Not advertising. Not sold. Not shared with data brokers.**
6. Retention: 12 months for raw events. Aggregates are kept and contain no identifiers.
7. Deletion, which Guideline 5.1.1(i) requires the policy to explain: the in-app controls, what opting out deletes, that deleting the app does not reach the
   server, and the email route quoting the analytics id.
8. Legal basis per region: consent everywhere, which is the legal basis in the EU and UK. The reviewer
   confirms Switzerland (§5.2) and the rest.
9. The existing MAL sync and image-load report facts, which are already owed.

## 11. Design

### 11.1 Components

| Type | File | Kind | Slice |
|---|---|---|---|
| `AnalyticsEvent`, `CatalogueIDs` | `MangaCarta/Models/AnalyticsEvent.swift` | value types and the wire encoder (§2.5) | 1 |
| `AnalyticsEligibility` | `MangaCarta/Models/AnalyticsEligibility.swift` | pure predicate (§3, §4) | 1 |
| `AnalyticsRegionPolicy` | `MangaCarta/Models/AnalyticsRegionPolicy.swift` | pure: `asksForConsent(storefrontCountryCode:localeRegionCode:)`, which picks the card (§5.2); the locale can only make it ask | 1 |
| `AnalyticsConsentStore` | `MangaCarta/Services/AnalyticsConsentStore.swift` | `@MainActor ObservableObject`: consent state, notice-shown flag, region re-evaluation | 1 |
| `AnalyticsEventBuffer` | `MangaCarta/Services/AnalyticsEventBuffer.swift` | file-backed FIFO, capped at 500, plus the install id | 1 |
| `AnalyticsRecorder` | `MangaCarta/Services/AnalyticsRecorder.swift` | `@MainActor`. `record(_:)` is **synchronous and network-free**, like the completion sink. It checks consent, then eligibility, then appends. Owns the sent ledger (§11.4). | 1 |
| `AnalyticsTransport`, `URLSessionAnalyticsTransport` | `MangaCarta/Services/AnalyticsTransport.swift` | protocol plus production `POST /v1/events` and `DELETE /v1/installs/{id}` | 2 |
| `AnalyticsUploader` | `MangaCarta/Services/AnalyticsUploader.swift` | `@MainActor`. Drains the buffer on `scenePhase == .active`, at most once every 15 minutes, 100 events per batch. Also sends queued deletes. | 2 |
| `AnalyticsNotice` | `MangaCarta/Views/Components/AnalyticsNotice.swift` | the §10.1 card | 1 |
| `AnalyticsSettingsSection` | `MangaCarta/Views/Components/AnalyticsSettingsSection.swift` | the §10.2 card and "What is sent" | 1 |
| `CoOccurrenceCandidateProvider` | `MangaCarta/Models/CoOccurrenceCandidateProvider.swift` | `CandidateProvider` over a downloaded table | 3 |
| Ingest Worker | outside this repo (owner's infrastructure) | endpoint, table, daily purge, aggregate job | 2 / 3 |

**Wiring is entirely at `AppComposition`.** The recorder is built after `WorkStore` and before
`HistoryStore`, then:

- The completion closure (`AppComposition.swift:314-316`) calls `malProgress?.chapterCompleted` **and**
  `recorder?.chapterCompleted`, in that order, so MAL sync is untouched.
- `lib.configureWorkLeftLibrary` gains the recorder's `workUnsaved` beside `UpdateNotifier.forget`. The
  composition already chains handlers like this.
- `LibraryStore` gains a `configureWorkSaved((Manga, WorkID) -> Void)` hook, called from `toggle`'s add
  branch. `RecommendationEngine` gains an optional `feedbackRecorded` closure. `RecommendationRail` and
  `MangaRail` and the detail-page MAL-native candidate rails gain optional `onOpen` hooks, defaulting
  to nil so existing call sites compile unchanged. The candidate hook receives
  `(MALDiscoveryCandidate, Int)`; its `to` is the candidate's MAL id, and only a candidate with an
  eligible `resolvedListing` may produce `mlt_opened`. The home `RecommendationRail` hook remains
  `(Manga, Int)` unchanged.
- Eligibility needs the registry (Source class), the `WorkStore` (Listings, external ids, snapshot)
  and `TagVocabularyStore`. These are passed as closures, following `listingParticipates`
  (`MALProgressCoordinator.swift:116`). The recorder never reads `SourceRegistry.shared`.
- `AnalyticsConsentStore` goes into the environment for the Settings section and the notice.

Related candidate opens do not emit an analytics event: they are navigation/context signals, not the
MAL recommendation signal measured by `mlt_opened`. This keeps the closed event set small and is the
recommended answer to Open question 9.

No `isolated` conformances, `nonisolated(nonsending)`, `@concurrent` or `Task.immediate` are used.
Everything is `@MainActor` classes and plain `Task {}` uploads, as `MALProgressCoordinator` does. That
is Swift 6.0-safe (CI's Xcode 16.4).

### 11.2 Consent state

```swift
enum AnalyticsConsent: String, Codable {
    case undecided      // never chose: collects nothing, in every region (§5.2)
    case granted        // "Share" or "OK"
    case denied         // "Not now" or "Turn off"
}
// isCollecting = consent == .granted
// The region decides only the card's wording: AnalyticsRegionPolicy.asksForConsent(...)
```

`UserDefaults` keys: `analytics.consent` and `analytics.noticeVersion`. The notice version is an `Int`,
so a future material change to §2 can raise it and show the notice again.

### 11.3 Buffer and upload

The buffer is JSON in `Application Support/analytics/buffer.json`, an array of encoded events, written
atomically on each append. Writes are tiny and infrequent: save, complete, feedback, and a few per day.
Upload sends `{ "v": 1, "events": [...] }`. The uploader runs only when `scenePhase == .active`,
so iOS cannot suspend an upload that began in the background. Responses are handled as follows:

- **2xx:** delete the sent events.
- **4xx:** drop the batch, so a schema rejection cannot loop.
- **5xx, or offline:** keep the events and retry next time, with backoff of 15 minutes doubling to 24
  hours.
- **Never during the reader's page loads.** Uploads start only on scene transitions.

An active-only upload can still be cut off by termination or connectivity loss; the existing 5xx/offline
retry path keeps the unsent batch and makes that cutoff safe.

### 11.4 Sent ledger

`Application Support/analytics/ledger.json` maps `WorkID` to `CatalogueIDs` for each Work whose
`work_saved` was **recorded**. It exists for two reasons:

- (a) `work_unsaved` has only a `WorkID`, so it can be sent only for a Work whose eligibility was
  already settled.
- (b) An unsave should never be the first event about a title.

The ledger is cleared with the id on opt-out and on reset.

## 12. Data and persistence changes

| Store | Location | New? | Cleared by |
|---|---|---|---|
| `analytics.consent`, `analytics.noticeVersion` | `UserDefaults.standard` (already declared, CA92.1) | new keys | never cleared automatically. This is the reader's choice. |
| `install.json`, `buffer.json`, `ledger.json`, `pending-deletes.json` (slice 2) | `Application Support/analytics/` | new directory | opt-out, reset, delete |
| `cooccurrence-v1.json` (slice 3) | `Caches/analytics/` | new | the system, freely. It is re-downloaded weekly. |

There are no changes to `works.json`, `HistoryStore`, `LibraryStore` persistence, `TasteProfileStore`
or `updates.json`. Nothing is migrated.

## 13. Errors and edge cases

- **The buffer file is unreadable or corrupt.** Start empty and overwrite it. Losing analytics is
  acceptable, and it never surfaces an error to the reader. A Settings row "What is sent" then shows an
  empty list.
- **Opt-out while an upload is in flight.** The uploader checks consent before each batch and after
  each response. If consent was revoked mid-request, it queues a delete for that id, so the in-flight
  batch is removed again.
- **The app is offline for weeks.** The buffer caps at 500, dropping oldest. `day` stays honest
  because it is recorded at event time.
- **A Work gains a MAL id after the event.** No back-fill. An event without ids was dropped, and
  re-sending history after the fact would be a new collection the reader never saw happen.
- **A Work is later reclassified as adult** (a new snapshot tag, or a Source re-declared `mixed`).
  Past events stay on the server until the purge. The ledger entry is removed, so no `work_unsaved`
  follows. This residual risk must be stated in the policy, or the server-side purge job can also drop
  rows whose MAL id appears in a server-side adult list. Open question 7.
- **Two Works merge** (ADR-0007). The ledger re-keys to the surviving `WorkID`, as other per-Work
  stores do.
- **Endpoint abuse.** There is no secret in an app binary. The Worker does not use per-IP limiting:
  Cloudflare isolates are short-lived and an in-memory counter would not provide a reliable limit.
  It rejects unknown `v`, unknown `name`, oversized batches (more than 100 events) and non-integer
  ids. Poisoned aggregates are bounded by k-thresholds on distinct installs, and a flood from one id
  counts once.
- **Delete for an unknown id** returns 204. The response never reveals whether an id existed.
- **A UI test or the simulator fixture** must never send. `-uitest-*` launch arguments, and any build
  without `ANALYTICS_ENDPOINT` in Info.plist, select a no-op transport. Debug builds default to the
  no-op transport.
- **The reader declares under 16.** The app targets 16+ (ADR-0022 Amendment 5). No COPPA-specific
  flow is designed. Open question 8 confirms.

## 14. Accessibility

- The notice is an inline card, not a modal, so it never traps VoiceOver focus. Its title has the
  `.isHeader` trait, and both buttons are full-width rows at least 44 pt tall with visible labels.
  Nothing relies on colour, and the two buttons are equal in weight (§10.1).
- The Settings toggle uses the native `Toggle`, so its label is the visible text. The footnote is read
  after it. "Delete my analytics data" has role `.destructive` and a confirmation dialog, read as
  "Delete analytics data? This removes everything sent from this device."
- "What is sent" rows are plain `Text`, so they scale with Dynamic Type. The id row is selectable and
  carries `accessibilityLabel("Analytics ID")` with the value read in groups.
- Every text style is a Dynamic Type style. There is no motion.
- Accessibility identifiers: `analyticsNotice`, `analyticsNotice.accept`, `analyticsNotice.decline`,
  `analyticsToggle`, `analyticsWhatIsSent`, `analyticsReset`, `analyticsDelete`.

## 15. Slices

Each slice merges on its own.

1. **Consent, toggle and a local buffer, with no network.** §11 slice-1 rows, the notice, the Settings
   section, the hooks, the eligibility checks, the buffer and the ledger. **Shippable alone.** It sends
   nothing, so the privacy label does not change. "What is sent" makes the behaviour visible for review
   on a real device. Includes the glossary entry and the `PRODUCT.md:38-39` link-back.
2. **Provider integration.** Transport, uploader, deletes, the Worker and its purge job, the manifest
   and label changes (§8), `submission-copy.md` §5, and the privacy-policy URL in Settings. The slice-2
   setup checklist must confirm Cloudflare Workers request logging, Workers Logs/observability and
   Logpush are disabled, so the policy's no-IP promise is true. **Blocked on the hosted privacy policy
   and the legal review.**
3. **Recommendation use.** The aggregate job, the published `cooccurrence-v1.json`,
   `CoOccurrenceCandidateProvider` behind `CandidateProvider` with k = 20, and its merge into the For
   You candidate list after the tag provider's. A golden test in the style of
   `RecommendationGoldenTests`. It stays dark (returns no candidates) while the table is empty. The
   weight-tuning analysis in §9 item 1 is offline work and needs no app slice.

## 16. Acceptance criteria

| # | Criterion | Test |
|---|---|---|
| 1 | An undecided reader collects nothing and has no install id, in every region including a non-consent storefront and locale. Only `.granted` collects. | `MangaCartaTests/AnalyticsConsentTests.testUndecidedCollectsNothingAnywhere` |
| 2 | An explicit choice is never overridden by a region change, and an undecided reader's card follows the current region. Locale changes cannot turn an asking card into an informing one. | `AnalyticsConsentTests.testExplicitChoiceSurvivesRegionChange`, `.testLocaleCannotLoosenAMissingStorefront` |
| 3 | The encoded wire form of every `AnalyticsEvent` case contains only the envelope keys and closed-set strings. No title, Source id, Listing id or chapter id appears. | `MangaCartaTests/AnalyticsEventTests.testWireFormHasOnlyClosedStrings` (encodes a fixture event with a distinctive title and Source id in the `Manga`, and asserts neither substring is in the JSON) |
| 4 | An `erotica` or `pornographic` title, an unrated title from a `mixed` Source, an `isNSFW` Source, an adult vocabulary tag and a missing Source each make the event ineligible, with the "Show adult content" switch on **and** off. | `MangaCartaTests/AnalyticsEligibilityTests.testAdultClassesAreIneligibleRegardlessOfSwitch` |
| 5 | A Work with any `local` Listing is ineligible, including when the event's own Listing is a remote one. | `AnalyticsEligibilityTests.testWorkWithAnyLocalListingIsIneligible` |
| 6 | An event whose Work has neither a MAL nor an AniList id is dropped. | `AnalyticsEligibilityTests.testWorkWithoutCatalogueIDIsDropped` |
| 7 | Saving, unsaving, completing a chapter, Not interested, More Like This and the home `onOpen` taps each append exactly one event while collecting; Related opens do not emit an event. Nothing records while not collecting. A manual Mark read appends nothing. | `MangaCartaTests/AnalyticsRecorderTests.testEachHookAppendsOnceWhenCollecting`, `.testRelatedOpenIsNotRecorded`, `.testNothingRecordedWhenNotCollecting`, `.testMarkReadRecordsNothing` |
| 8 | `work_unsaved` is recorded only for a Work in the sent ledger. | `AnalyticsRecorderTests.testUnsaveRequiresLedgerEntry` |
| 9 | Opting out deletes the buffer, the id and the ledger. Opting in again mints a different id. | `AnalyticsRecorderTests.testOptOutErasesLocalState` |
| 10 | MAL progress sync behaves exactly as before with the fanned-out completion closure. | the existing `MALProgressCoordinatorTests`, unchanged and green, plus `AppCompositionTests.testCompletionReachesBothSinks` |
| 11 | The buffer caps at 500, dropping the oldest, and recovers from a corrupt file by starting empty. | `MangaCartaTests/AnalyticsEventBufferTests.testCapDropsOldest`, `.testCorruptFileStartsEmpty` |
| 12 | `asksForConsent(storefrontCountryCode:localeRegionCode:)` is true for every EEA and UK code (alpha-2 and alpha-3), for a nil storefront regardless of locale, and for an EEA/UK locale with another storefront; locale never removes a storefront's asking card. It is false for Switzerland and for other storefront and locale codes. | `AnalyticsConsentTests.testRegionTable`, `AnalyticsConsentTests.testLocaleCannotLoosenAMissingStorefront` |
| 13 | The first-launch notice is inline, stays across launches until a button is tapped, dismisses on either button, does not reappear after, and its two buttons have equal styling. Before a tap, no event is recorded. The Settings toggle reflects and changes consent. | `MangaCartaUITests/AnalyticsSettingsUITests.testNoticeDismissesAndToggleReflectsChoice` (hermetic: `-uitest-analytics-region GBR` / `USA` launch argument, no-op transport) |
| 14 | (slice 2) A 2xx deletes the sent events, a 4xx drops them, and a 5xx keeps them. Opting out queues a delete for the old id, which is retried until it succeeds. | `MangaCartaTests/AnalyticsUploaderTests` (stub `AnalyticsTransport`) |
| 15 | (slice 2) UI tests and Debug builds never construct the network transport. | `AnalyticsUploaderTests.testUITestLaunchUsesNoOpTransport` |
| 16 | (slice 2) The manifest declares Device ID (linked, Analytics) and Product Interaction with both purposes. | `MangaCartaTests/PrivacyManifestTests.testAnalyticsEntries` (parses the bundled plist) |
| 17 | (slice 3) The co-occurrence provider returns nothing for pairs below k, never returns an id the reader has read, saved or dismissed, and returns nothing for an empty table. | `MangaCartaTests/CoOccurrenceCandidateProviderTests` |

### Files that need `xcp add-file`

`MangaCartaTests/` and `MangaCartaUITests/` are not synchronized groups. Every new test file needs
`xcp add-file … --targets <target>`: `AnalyticsConsentTests.swift`, `AnalyticsEventTests.swift`,
`AnalyticsEligibilityTests.swift`, `AnalyticsRecorderTests.swift` and `AnalyticsEventBufferTests.swift`
(slice 1); `AnalyticsUploaderTests.swift` and `PrivacyManifestTests.swift` (slice 2);
`CoOccurrenceCandidateProviderTests.swift` (slice 3), all `--targets MangaCartaTests`; and
`MangaCartaUITests/AnalyticsSettingsUITests.swift` with `--targets MangaCartaUITests`. Check
`git diff --stat` on `project.pbxproj` immediately before `git add` (CLAUDE.md, "Adding files").

App sources go in `Models/`, `Services/` and `Views/Components/`, which are synchronized, so no
`pbxproj` edit is needed. The only `Views/` change is an edit to the existing `SettingsView.swift`
and `HomeView.swift`, not a new file.

## Open questions for the owner

Each has a recommended answer, so the whole list can be approved in one pass.

1. **Provider: self-hosted endpoint, or TelemetryDeck?** *Recommended: self-hosted* (a Cloudflare
   Worker with D1 or equivalent, about $0–5 a month at launch scale). It is the only option that can
   honour "delete my data" and give raw rows for co-occurrence. TelemetryDeck needs no server and is
   hosted in the EU, but it cannot delete one user's events and it adds the app's first SDK.
2. **Device ID on the label. Settled by the research: "Linked: Yes"** (§8). No longer a choice: Apple counts
   personal data under privacy law as linked, and a persistent id with a history is personal data under the
   GDPR.
3. **One toggle, or a UK/EU split? Settled 2026-11-11: one toggle.** The split relied on the ICO's
   exception, which §5.1 rules out, and the owner's consent-first decision makes it moot.
4. **Retention and shared models: keep raw events 12 months, keep k ≥ 20 aggregates indefinitely,
   and allow historical events to train shared recommendations *only* as those aggregates and offline
   weight tuning?** *Recommended: yes to all three*, stated in the privacy policy.
5. **No in-app export file, with the "What is sent" list plus email access requests instead?**
   *Recommended: yes.* The device already holds a superset of what is sent.
6. **Collect `source_installed` with only the adult class?** *Recommended: yes.* It tells you how
   many readers the age gate affects, without naming any Source. Drop it if even the class feels too
   much.
7. **A Work reclassified as adult after events were sent: accept a 12-month residual, or have the
   server purge rows whose MAL id is on a server-side adult list?** *Recommended: add the server
   purge in slice 2.* It is one join against MAL's public adult genre ids.
8. **Legal review before slice 2, plus the hosted privacy policy URL.** *Recommended: required.* The review
   also settles Switzerland's row (§5.2, high-risk profiling) and whether "OK" on an informing card satisfies
   Guideline 5.1.1(ii).
   Slice 2 does not merge without both. Also confirm that the 16+ age rating means no
   children's-privacy flow is needed.
9. **Should a Related-rail open emit an event?** *Recommended: no.* Related is contextual navigation,
   while `mlt_opened` measures the MAL recommendation rail; keeping Related out avoids adding a
   second open event without a settled product question.

## Owner decisions (2026-11-12)

The owner approved every recommended answer above in one pass:

1. **Provider: self-hosted** (Cloudflare Worker + D1 or equivalent). Not TelemetryDeck.
4. **Retention:** raw events 12 months; k ≥ 20 aggregates kept indefinitely; historical events train shared
   recommendations only as those aggregates and offline weight tuning. Stated in the privacy policy.
5. **No in-app export file.** The "What is sent" list plus email access requests.
6. **`source_installed` is collected, with only the adult class.**
7. **Server purge** of rows whose MAL id is on a server-side adult list, in slice 2.
8. **Legal review and the hosted privacy-policy URL are required before slice 2 merges**, including Switzerland's
   row, whether "OK" on an informing card satisfies Guideline 5.1.1(ii), and confirming that the 16+ rating needs
   no children's-privacy flow.
9. **Related-rail opens emit no event.**

Questions 2 and 3 were already settled (Linked: Yes; one toggle). The owner also directed that **slice 1 be built
next** (2026-11-12).

