# Per-title reading mode — design

- **Date:** 2026-09-30
- **Issue:** [#290](https://github.com/eliasmagdaleno/MangaCarta/issues/290)
- **Decision record:** [ADR-0026](../../adr/0026-reading-mode-is-per-work.md) owns the *why*; this
  spec owns the *how*.

## Goal

Open any title and it reads in the mode last chosen for *that* title; changing one title never
moves another. Reading mode is the three-way `ReadingMode` (`leftToRight`, `rightToLeft`,
`vertical`) in `Views/ReaderView.swift`.

## 1. Model — `ReadingModeStore`

New file `MangaCarta/Services/ReadingModeStore.swift` (synchronized group; no pbxproj edit).
`ReadingMode` moves out of `ReaderView.swift` into `Models/ReadingMode.swift` so the store does not
depend on a view file.

```swift
@MainActor
final class ReadingModeStore: ObservableObject {
    init(defaults: UserDefaults = .standard, works: WorkStore)

    /// The global default. Stored under the existing `readingMode` key (the old
    /// `@AppStorage` key) with the same raw values, default `.rightToLeft`.
    @Published var defaultMode: ReadingMode

    func mode(for workID: WorkID) -> ReadingMode?        // the Work's own mode
    func effectiveMode(for workID: WorkID?) -> ReadingMode  // own mode ?? defaultMode; nil id → default
    func set(_ mode: ReadingMode, for workID: WorkID)
    func clear(for workID: WorkID)
    /// Sets `mode` only when the Work has none. Returns whether it wrote.
    @discardableResult func seed(_ mode: ReadingMode, for workID: WorkID) -> Bool
}
```

- **Persistence:** `UserDefaults`, like `SourcePreferenceStore` (small, flat, needed on the
  reader's first paint). Per-Work modes live under `reader.workModes` as JSON
  `[workID.raw.uuidString: ReadingMode.rawValue]`. An unknown raw value is dropped on load.
- **Publishing:** the per-Work dictionary is `@Published private`, so views that read
  `effectiveMode` re-render on change.
- **Merges.** The rule is `UpdateStateStore.reconcileMerges`': a stored key is resolved with
  `works.work(key)?.id`; a key resolving to another id belongs to that survivor unless the survivor
  has its own entry (survivor wins); a key resolving to nothing is ignored. Applied in two places,
  because a merge can happen mid-session (`MetadataUpgradeQueue`):
  - **Reads are pure.** `mode(for:)` / `effectiveMode` are called from `ReaderView.body`, so they
    must not mutate `@Published` state. They return `stored[id]` if present, else the value of the
    stored key that resolves to `id` (several merged-away keys: the lexicographically smallest key,
    for determinism). The dictionary is tiny, so the scan is free.
  - **Writes re-key.** `set` / `clear` / `seed` first rewrite the dictionary under the rule above
    (moving, dropping), then apply the change and save once. `clear(for:)` removes the id's own
    entry *and* any merged-away key resolving to it, so `Default` really means default.
- **Composition:** built in `AppComposition` with the graph's `WorkStore` and defaults, injected
  with `.environmentObject`. No `shared` singleton.

## 2. Reader and Settings

**Reader (`ReaderView`).**
- Replace `@AppStorage("readingMode") private var mode` with a computed mode:
  `readingModes.effectiveMode(for: workID)`, where
  `workID = works.workId(for: ListingKey(sourceId: manga.sourceId, mangaId: manga.id))`.
  `ReadingModeStore` and `WorkStore` come from the environment.
- Every existing read of `mode` keeps working against the computed value; the mode-switch position
  handoff (ADR-0014 decision 8) is unchanged.
- **Menu:** one `Picker` with four entries, bound to a `ReadingMode?` selection:
  - `Default (<defaultMode.label>)` — tag `nil`; selecting it calls `clear(for:)`.
  - the three modes — selecting one calls `set(_:for:)`, even when equal to the default.
  - The tick is on `Default` exactly when `mode(for:)` is nil.
  - With no Work id (should not happen: opening a chapter mints one), the picker edits
    `defaultMode` and the `Default` entry is hidden.
- **Accessibility:** `accessibilityValue` is `"<label>, default"` or `"<label>, this title"`.
  Add the identifier `readerModeMenu` for UI tests.

**Settings (`SettingsView`).** A **Reader** section between Appearance and Updates:
`InkSectionHeader("Reader", eyebrow: "Reading")`, a `Picker("Default reading mode")` bound to
`readingModes.defaultMode`, and the caption "Titles you've set a mode for in the reader keep it."

**Detail page:** unchanged.

## 3. ComicInfo seeding

- `ComicInfo` gains `let manga: String?`, parsed from `<Manga>` with the existing `value(_:)` trim.
  It is `Codable` and stored in `LocalItemRecord`; the synthesized decoder treats the missing key
  in older records as nil. Old records are not backfilled.
- `ComicInfo.readingMode: ReadingMode?` maps, case-insensitively: `YesAndRightToLeft` →
  `.rightToLeft`, `No` → `.leftToRight`, anything else (`Yes`, `Unknown`, absent) → nil.
- `LocalImportViewModel`, in the `MainActor.run` block after `library.toggle(manga)` /
  `updateLocalItem` (the Work now exists): if `record.comicInfo?.readingMode` is non-nil and
  `works.workId(for: ListingKey(sourceId: LocalSource.sourceID, mangaId: mangaID))` resolves, call
  `readingModes.seed(mode, for: workID)`. `record` is the file just imported, so in a grouped series
  the first imported file with a usable value wins and later files cannot overwrite it.
- `configure(registry:library:works:)` gains the `ReadingModeStore`.

## 4. Edge cases

| Case | Behaviour |
|---|---|
| Default changed | Only Works with no own mode follow it. |
| Work merged | Own mode moves to the survivor; survivor's own mode wins a conflict. |
| Local import deleted / Source uninstalled | Mode kept (like pins and history); harmless. |
| Reader picks the mode equal to the default | Stored as the Work's own mode. |
| ComicInfo on a Work that already has a mode | Ignored. |
| `Default` chosen after seeding | Stays cleared: seeding runs only at import. Importing *another* file of that series with a usable `Manga` value seeds again, because the Work then has no own mode. Accepted. |
| Existing install | `readingMode` value becomes `defaultMode`; no Work has an own mode yet. |

## 5. Tests

Unit (Swift Testing, `TestDefaults` / `TestDirectory` for isolation):
1. `effectiveMode` returns the own mode when set, the default otherwise, and the default for a nil id.
2. `set` / `clear` / `seed` (seed writes only when none; returns whether it wrote).
3. Persistence round-trip through a second store on the same defaults; unknown raw value dropped.
4. An existing `readingMode` value is read as `defaultMode`; changing `defaultMode` writes that key.
5. Merge: a read after a merge returns the loser's mode for the survivor without publishing; the
   survivor's own mode wins; a write re-keys and drops unresolvable keys; `clear` on the survivor
   also clears a merged-away key.
6. `ComicInfo` parses `<Manga>` and maps the four values plus absent; an old record without the key
   decodes.
7. Import seeding: a `YesAndRightToLeft` import gives the Work `.rightToLeft`; a second file in the
   same series with `No` does not change it; an import into a Work that already has a mode leaves it.

Hermetic UI test (`MangaCartaUITests`, existing local-import fixtures): set Left to Right on title A
from the reader menu; open title B and see the default ticked; reopen A and see Left to Right.

## Out of scope

Source-supplied defaults (ADR-0026 Consequences), a detail-page control, backfilling ComicInfo for
old imports, per-Listing modes.
