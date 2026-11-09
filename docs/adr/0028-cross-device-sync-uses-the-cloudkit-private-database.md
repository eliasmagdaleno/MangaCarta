# ADR-0028 — Cross-device sync uses the CloudKit private database, record by record

- **Status:** Proposed (2026-11-09)
- **Related:** ADR-0001, ADR-0003 (Amendments 4, 7, 10), ADR-0007, ADR-0008, ADR-0021,
  ADR-0022, ADR-0025, ADR-0026, ADR-0027
- **Handoff queue:** item 13

## Context

Everything a reader builds in MangaCarta stays on the device it was built on. Nothing in the app
syncs today: there is no `.entitlements` file in the repository, and a search of `MangaCarta/` for
`CloudKit` or `ubiquity` finds nothing. `iCloud` appears once, in a comment about copying a file
the reader opened in place from iCloud Drive (`LocalLibraryStore.swift:65`). A reader with an
iPhone and an iPad keeps two libraries, two histories and two sets of read marks.

The decision is not only which transport to use. Three facts in the code mean the same title has
**different keys on different devices**. Copying data between devices, by any transport, would
show duplicates and miss matches unless those keys are dealt with first:

1. **Work ids are minted per device.** `WorkStore.mint(from:)` gives a new Listing a fresh
   `WorkID()` (`WorkStore.swift:142`, `:166`), and `WorkID` is a random UUID
   (`Work.swift:15-18`). Two devices that each open the same Listing create two Works. The store
   already merges Works that share an external id, but the **incumbent survives**
   (`WorkStore.swift:368`, ADR-0008). "Incumbent" means whichever arrived first on *this* device,
   so two devices can merge the same pair in opposite directions. Loading a file in which two
   Works claim one Listing silently lets the last one win the index (`WorkStore.swift:435`).
2. **Installed Source ids carry a device-minted repository UUID.** A qualified Source id is
   `"<repository uuid>:<localId>"` (`ExtensionInstaller.swift:235`). The UUID is minted when the
   repository is first added (`ExtensionInstaller.swift:281`; ADR-0003 Amendment 4, decision 2).
   Every `ListingKey` from an installed Source therefore differs between two devices that added
   the same repository URL. That covers history, library, Work listings and pins. The installer
   can already accept an id instead of minting one (`repositoryID requestedID: UUID? = nil`,
   `ExtensionInstaller.swift:273`).
3. **Local items are the exception, and a lucky one.** `local` is a fixed Source id
   (`LocalSource.swift:4`). An imported item's id is the first 32 hex digits of the file's
   SHA-256 (`LocalLibraryStore.swift:92-94`). The same file imported on two devices gets the same
   `ListingKey`. The bytes stay on-device (ADR-0025).

The stores involved, from `MangaCarta/Services/*Store.swift` plus the MAL outbox:

| Store | Persists in | Keyed by |
|---|---|---|
| `WorkStore` | `works.json`: Works and aliases (`WorkStore.swift:46`, `:465-472`) | `WorkID` |
| `HistoryStore` | UserDefaults `history.entries`, `history.readMarks` (`HistoryStore.swift:121-122`); log capped at 500 (`:124`) | Listing + chapter id |
| `LibraryStore` | UserDefaults: items and collections (`LibraryStore.swift:435-451`) | Listing |
| `ReadingModeStore` | UserDefaults `readingMode`, `reader.workModes` (`ReadingModeStore.swift:21-22`) | `WorkID` string |
| `SourcePreferenceStore` | UserDefaults `source.primaryID`, `source.workChoices` (`SourcePreferenceStore.swift:34-35`) | `WorkID` string → `ListingKey` |
| `UpdateStateStore` | `updates.json` (`UpdateStateStore.swift:32`) | `WorkID` |
| `RepositoryStore` | `repositories.json` plus script files (`RepositoryStore.swift:112-114`) | repository UUID |
| `TasteProfileStore` | UserDefaults `taste.notInterested`, `taste.moreLikeThis` (`TasteProfileStore.swift:36-37`) | bare `manga.id` (`RecommendationEngine.swift:149`) |
| `EntityResolutionStore` | UserDefaults cache (`EntityResolutionStore.swift:95-96`) | Listing → MAL id |
| `AniListPoolStore`, `TagVocabularyStore` | `Caches/` (`AniListPoolStore.swift:31-32`, `TagVocabularyStore.swift:83-84`) | — |
| `LocalLibraryStore` | the imported pages and covers under Application Support (`LocalLibraryStore.swift:9`) | content hash |
| `MALAccountStore` | UserDefaults display cache (`MALAccountStore.swift:420-454`) | — |
| `MALCredentialStore` | Keychain, `AfterFirstUnlockThisDeviceOnly` (`MALCredentialStore.swift:142`) | — |
| `MALProgressOutbox` | `mal-progress-outbox.json` (`MALProgressOutbox.swift:87`) | — |

Two shapes of data matter for conflicts. Some state only grows: Works' listings and titles,
aliases, and reading progress (monotonic per ADR-0014, `HistoryStore.swift:156-170`). Other state
is undone: `markUnread` **deletes** entries and marks across the whole Work
(`HistoryStore.swift:308-315`; ADR-0027). A read mark carries no timestamp
(`HistoryStore.swift:100-111`). A deletion that is not recorded cannot be synced, because the
other device's copy simply comes back.

## Decision

**Sync uses the CloudKit private database, driven by `CKSyncEngine`, with one record per
syncable fact in a custom zone.** It is opt-in from Settings and dormant without an iCloud account.
Small device-independent settings use `NSUbiquitousKeyValueStore`. No file-level sync and no
server of our own.

`CKSyncEngine` is available from iOS 17.0
([CKSyncEngine](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5);
platform data from the documentation's JSON, read 2026-11-09). The deployment target is iOS 17.5
(`project.pbxproj:817`), so no availability branching is needed.

### Identity comes first, and converges deterministically

- **Same Listing, two Works → merge.** When a synced Work names a `ListingKey` that a different
  local Work already holds, the two are merged. A Listing is one Source's copy of one title
  (ADR-0001), so this is not a guess.
- **The survivor is chosen the same way on every device:** the Work whose `WorkID` UUID string
  sorts first. This replaces "the incumbent survives" (ADR-0008) **for every merge once sync is
  on**, including merges on external ids and manual links (ADR-0005). If one device kept the
  incumbent rule, two devices could alias X→Y and Y→X. The alias walk then finds no live Work and
  returns nil after 32 steps (`WorkStore.swift:70`), and the title disappears. It is an
  amendment to ADR-0008, written when this ADR is accepted.
- **Aliases are synced records and are never deleted.** A merge on one device converges on the
  other because the alias arrives and every Work-keyed store already follows aliases
  (`UpdateStateStore.reconcileMerges`, `ReadingModeStore`'s re-key, `SourcePreferenceStore`).
- **Repository identity is synced, installs are not.** A repository record (UUID, index URL,
  name, state) is synced. Adding the same URL on a second device adopts the synced UUID through
  `requestedID`, so qualified Source ids, and with them every `ListingKey`, match. The UUID was
  still minted once, by an installer, and is not derived from the URL, so ADR-0003 Amendment 4
  holds. A device that already added that URL under its own UUID is reconciled the same way:
  the UUID that sorts first wins, and the other device's data is re-keyed through the reconnect
  path of ADR-0003 Amendment 7. The reader confirms that, as they do today.
- **Scripts and installs never sync.** A synced repository shows on the other device as "added on
  another device — install?". The install acknowledgement sheet (ADR-0022 Amendment 2, ADR-0003
  Amendment 10) is shown on every device that installs. Executable code is not something a device
  should receive without its reader acting.

### Merge rules per kind of record

| Record | Rule |
|---|---|
| Work | Union. Listings, `knownTitles` and external ids only accumulate (`Work.swift:44-55`, `:128-134`). The snapshot goes to the higher rank (`WorkStore.swift:319-321`). `displayTitle` goes with the survivor. |
| Alias | Insert-only. |
| Reading progress (a `ReadingEntry`) | One record per Listing + chapter. **Furthest position wins** (the same monotonic rule as `record`), with `updatedAt` taking the later value. |
| Chapter read state | One record per Listing + chapter ordinal. It holds the latest **explicit** action, `read` or `unread`, and when it happened. **The latest explicit action wins.** An `unread` action also hides any progress recorded before it. Progress recorded *after* an `unread` counts again. |
| Library item, collection membership | One record per Listing (per collection). Latest change wins, with removal recorded as a tombstone. |
| Per-Work reading mode | One record per Work: the mode or "follows default", latest wins. Merges keep the survivor's (ADR-0026). |
| Per-Work source pin | One record per Work, latest wins. Merges keep the survivor's. |

So the answer to "read wins or latest wins?" is **both, for different things**. Passive reading
only ever adds, because reading further is never undone by reading less. Explicit marks are a
statement by the reader, and the most recent one is what they meant. `isRead` stays as ADR-0027
defines it, read to the end or marked: it is computed from the merged records, never stored.

Timestamps are the writing device's clock. Skew between two of one reader's devices is accepted.
The reader is the only writer, and a conflict needs two contradicting marks on one chapter within
the skew.

### Per store

| Store | Decision | Why |
|---|---|---|
| `WorkStore` (Works, aliases) | **Sync** | Everything Work-keyed depends on it. |
| `RepositoryStore`: repository records | **Sync** | Makes Listing keys match. |
| `RepositoryStore`: installed bundles, script bytes | **Don't sync** | Executable code. Each device installs, and is asked. |
| `HistoryStore` (progress and read state) | **Sync** | The headline value. |
| `LibraryStore` (items, collections) | **Sync** | The headline value. |
| `ReadingModeStore`: per-Work modes | **Sync** | A fact about the title (ADR-0026). |
| `ReadingModeStore`: default mode | **Sync, through the key-value store** | One small device-independent value. |
| `SourcePreferenceStore`: per-Work pins | **Later** | Meaningful only once repository ids match, and wrong if the pinned Source isn't installed on this device. |
| `SourcePreferenceStore`: primary source | **Later**, key-value store | Same reason. |
| `UpdateStateStore` | **Don't sync** (frontier, baselines, backoff); **later** (`isMuted`) | Frontiers are per-device checking state. Syncing them half-way would make one device skip notifications the other never sent. Mute is a reader's choice and can follow. |
| `TasteProfileStore` | **Later** | Keyed by a bare `manga.id` with no Source (`RecommendationEngine.swift:149`). The same file already calls a bare-`mangaId` key a cross-source collision for its legacy cache (`TasteProfileStore.swift:26-28`). Re-key to Work ids first. |
| `EntityResolutionStore`, `AniListPoolStore`, `TagVocabularyStore` | **Don't sync** | Caches. Each device can rebuild them. |
| `LocalLibraryStore` | **Never** | ADR-0025: bytes stay on-device. |
| `MALCredentialStore` | **Never** | Tokens are in the Keychain marked `ThisDeviceOnly` on purpose. Each device signs in itself. |
| `MALAccountStore` | **Don't sync** | A display cache of the signed-in account. It follows each device's sign-in. |
| `MALProgressOutbox` | **Never** | Two devices draining one queue would write MAL twice. Each device writes MAL for the reading it did. |
| `settings.showAdultSources` | **Don't sync** | See open question 4. |

### What another device shows

- **A local Work** syncs its Work, library row and read state, but not the bytes or the cover.
  For a local item, `coverURL` points into this device's container (it is re-rooted on decode, `LibraryStore.swift:44`), so it is dropped. The other device shows
  the row with a placeholder cover and "Import this file to read it here". Importing the same file
  produces the same id, so the row and its read state attach to the import with no extra matching.
  A different scan of the same series is a different file and a different item, as it is today.
- **A Work whose Source is not installed here** shows like a Work whose Source was disabled: its
  Listings, history and read state are kept, and it fails as unavailable when opened. That is
  the existing rule (`CLAUDE.md`, "Current state"). The library row offers the repository install.

### Notifications (ADR-0021)

Update state does not sync, so **each device notifies on its own** for the Works it checks. A
reader with two devices may get the same chapter alert twice. That already happens today, and
ADR-0021 deferred dedupe to exactly this point. Reading a chapter on one device syncs its read
state, and the other device's Updates surface drops it because the surface reads from
read state (ADR-0027). Proper dedupe needs a shared "announced" set and is a later amendment.

## Options considered

### A. CloudKit private database with `CKSyncEngine` — chosen

- **Data model fit:** good. Records are typed field sets, so each fact above is its own record,
  and an unrelated change on another device never overwrites it. One send batch holds at most 250
  records, and `CKSyncEngine` splits sends into batches itself.
- **Conflict resolution:** the app owns it. A save against a newer server version fails with
  `serverRecordChanged`. The error carries the client, server and ancestor copies, and the app
  merges into the server copy and saves again
  ([CKError.Code.serverRecordChanged](https://developer.apple.com/documentation/cloudkit/ckerror/code/serverrecordchanged)).
  The engine retries transient errors and throttling by itself. It does not resolve conflicts
  ([CKSyncEngine](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5)). That
  is the right split: the rules above are domain rules, and no library could know them.
- **Cost:** none to the developer for the private database. Storage counts against the
  **reader's** iCloud storage, and a full account fails saves with `quotaExceeded`
  ([CKError.Code.quotaExceeded](https://developer.apple.com/documentation/cloudkit/ckerror/code/quotaexceeded)).
  This data is kilobytes, but the failure has to be handled.
- **Privacy label:** Apple defines "collect" as sending data off the device "in a way that allows
  you and/or your third-party partners to access it"
  ([App privacy details](https://developer.apple.com/app-store/app-privacy-details/)). The
  private database is "accessible only to the user of the current device"
  ([CKDatabase](https://developer.apple.com/documentation/cloudkit/ckdatabase)), so the developer
  cannot read it. That page says nothing about iCloud specifically, so this reasoning is an
  inference, not something Apple states. See open question 3.
- **Offline:** changes queue locally. The engine schedules sends and fetches "depending on good
  system conditions" (account, network, battery), and the app must persist its
  `State.Serialization` across launches. Without an account it stays dormant.
- **What changes:** entitlements for CloudKit and remote notifications (the engine requires both),
  plus a CloudKit container. A sync layer maps store changes to records and back. Tombstones and
  timestamps for read marks and library removals. The deterministic merge survivor. Repository-id
  adoption. Every syncable store gains a "changes since" seam.

### B. `NSUbiquitousKeyValueStore` for everything — rejected; kept for small settings

- **Fit:** at most 1,024 keys and 1 MB in total. Values must be property-list types
  ([NSUbiquitousKeyValueStore](https://developer.apple.com/documentation/foundation/nsubiquitouskeyvaluestore)).
  A 500-entry history and a library would fit only as a few whole-blob values. Each blob would
  then be one conflict unit, so a mark on one device overwrites the other's whole history.
- **Conflict:** per key, wholesale. The app learns of a change through
  `didChangeExternallyNotification` and cannot merge inside a value.
- **Cost / privacy / offline:** free. Without an account, values stay on the device. Apple warns
  against storing personal data there, because it is stored unencrypted on disk.
- **Use:** the global default reading mode, and later the primary source. Both are single
  values, and the latest one winning is the right rule for them.

### C. iCloud Drive documents (sync the JSON stores as files) — rejected

- **Fit:** poor. Four of the stores to sync are in UserDefaults, not files, and would have to
  move. `works.json` and `updates.json` are whole-store files, so one changed Work rewrites the
  file.
- **Conflict:** whole-file. Concurrent writes leave conflict versions that the app must find and
  merge itself
  ([NSFileVersion.unresolvedConflictVersionsOfItem(at:)](https://developer.apple.com/documentation/foundation/nsfileversion/unresolvedconflictversionsofitem(at:))).
  That is a three-way JSON merge of the entire store, after the fact, with no ancestor copy.
- **Offline:** files can be in the cloud and not yet downloaded. The stores load synchronously at
  launch (`WorkStore.loadIfNeeded`), and could not wait for a download.
- **Cost / privacy:** the same as A. But the files sit in a container a reader can browse and
  edit by hand.

### D. A server of our own, or a third-party sync service — rejected

- No backend exists, and building one means accounts, auth, operations and abuse handling, the
  same weight that made ADR-0021 phase one device-only.
- **Privacy label:** reading history linked to an account on our server is collected data, and
  would add new linked types to the label.
- **Gain:** Android or web clients, which nobody has asked for. Revisit only if one is planned.

### E. SwiftData / `NSPersistentCloudKitContainer` — rejected

- It would mean migrating every store to a managed model, which is a rewrite of the persistence
  layer.
- It mirrors objects with its own last-writer merge. The deterministic survivor, insert-only
  aliases and tombstoned marks above would have to be built on top of it, against its grain.

## Consequences

- **ADR-0008 is amended** so a merge's survivor is deterministic, not the incumbent. On a single
  device the only visible effect is which `displayTitle` is kept after a merge.
- **ADR-0027's storage changes, not its meaning.** Read marks gain a timestamp, and `markUnread`
  records an explicit `unread` action instead of only deleting. `isRead` is computed exactly as
  before.
- **The 500-entry history cap applies after merging.** A complete entry dropped by the cap becomes
  a read mark, as `preserveReadMarks` already does.
- Two devices on different app versions may disagree on a record's shape. Records carry a schema
  version, and a device ignores fields it does not know but keeps them.
- Turning sync off keeps local data and stops sending. "Delete synced data" removes the zone. It
  is a separate, explicit action.
- The privacy text and App Store answers are reviewed before shipping (open question 3).

## First slice, safe to ship alone

**Slice 1: identity convergence, with no reading data.**

1. The deterministic merge survivor for all merges (the ADR-0008 amendment). It is useful
   without sync too. A repairing launch walks Works in the order they were saved, which is
   `Array(works.values)` (`WorkStore.swift:411`), and that order is random per process. So even on
   one device the "incumbent" of a load-time repair is not stable today.
2. Entitlements, container and `CKSyncEngine` wiring behind a Settings switch that is **off by
   default**, with persisted engine state.
3. Sync **Works, aliases and repository records** only. Adopt synced repository UUIDs on add.
   Reconcile an already-added repository through the Amendment 7 reconnect path, which asks first.

It is safe alone because every effect is one the app already accepts. A merge happens only when
two Works hold the same Listing, so they were the same title anyway. A repository re-key reuses a
verified, reader-confirmed migration. A failed sync leaves each device as it is today. It is also
the prerequisite for everything else: syncing history before repository ids match would duplicate
every installed Source's Work.

It ships no reader-visible value except a converged Work list. **Slice 2** is the value: history,
read state, library and per-Work reading mode, plus the default mode through the key-value store.
**Slice 3:** pins, primary source, taste feedback (after re-keying it to Works), mute, and
notification dedupe as an amendment to ADR-0021.

## Open questions for the owner

1. **Is this worth a slice that shows nothing yet?** Slice 1 is plumbing. *Recommended:* yes. The
   alternative is syncing history first and getting duplicate Works for every installed Source.
   The other ordering cannot be made safe.
2. **Should a synced repository install itself on the other device?** *Recommended:* no. Show it
   as "added on another device" and install on a tap, with the acknowledgement sheet on each
   device. Scripts are code, and the disclosure in ADR-0003 Amendment 10 is per install.
3. **Does the privacy label change?** *Recommended:* add no new data type. The private database
   is not readable by the developer, which falls outside Apple's definition of "collect". Mention
   iCloud sync in the in-app privacy text anyway, and re-read Apple's guidance when submitting.
   Apple does not address iCloud on that page, so the label answer is the owner's call.
4. **Should "Show adult content" (`settings.showAdultSources`) sync?** *Recommended:* no. It sits
   next to a declared-age confirmation that ADR-0022 ties to a reader's install gesture, and a
   shared iPad is the device where it should not change silently.
5. **Read state: is "latest explicit mark wins, progress only adds" right?** *Recommended:* yes.
   The case it decides is "marked unread on the phone, then read on to the end on the iPad". That
   reads as read, because the later reading is newer than the unmark.
6. **Notification dedupe across devices?** *Recommended:* not in slices 1–2. Each device notifies
   for its own checks, as today. Read state syncing already clears the other device's Updates
   surface. Dedupe is slice 3, as an ADR-0021 amendment.
7. **Sync on by default once it is stable?** *Recommended:* off by default through slice 2, then on
   by default once it has run on the owner's devices for a release. It is a reader's data, and the
   first build of a sync layer should not be the one that changes it without asking.

## Amendments

Amend, never correct. A change to this decision is recorded as a dated amendment below,
and the text above stays as written.
