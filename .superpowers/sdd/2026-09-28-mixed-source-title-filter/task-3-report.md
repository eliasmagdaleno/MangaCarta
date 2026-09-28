# Task 3 Report: The active browse Source respects the switch

## Status

DONE_WITH_CONCERNS

## Implemented

- Added `SourceRegistry.init(sources:showAdultContent:)` with the stored
  `private let showAdultContent: () -> Bool` closure.
- Made initialization, `active`, and `firstBrowsable` reject whole-source adult
  Sources while the switch is off, while allowing mixed Sources.
- Added the four required `SourceRegistryTests` cases and the shared `StubSource`
  shape required by the following task.
- Restored privacy redaction for mixed Sources in update notifications by using
  `AdultContentSetting.key` and `isNSFW || declaresAdultTitles`.
- Updated refresh event adult classification with the same predicate.
- Added a notification test proving a mixed Source's title is redacted while the
  adult switch is off.

## TDD evidence

RED command:

```sh
xcodebuild -scheme MangaCarta -destination 'platform=iOS Simulator,id=ADDAB2F8-38C7-4D44-97EA-4E98281CF691' test -only-testing:MangaCartaTests/SourceRegistryTests
```

The command did not reach compilation. It failed because the environment could
not connect to CoreSimulatorService:

```text
CoreSimulatorService connection became invalid. Simulator services will no longer be available.
Error ... Connection refused ... Failed to initialize simulator device set.
```

Per the simulator instruction, this was the only test attempt; no retry was made.

GREEN command required but not runnable in this environment:

```sh
xcodebuild -scheme MangaCarta -destination 'platform=iOS Simulator,id=ADDAB2F8-38C7-4D44-97EA-4E98281CF691' test -only-testing:MangaCartaTests/SourceRegistryTests
```

Full unit command required but not runnable in this environment:

```sh
xcodebuild -scheme MangaCarta -destination 'platform=iOS Simulator,id=ADDAB2F8-38C7-4D44-97EA-4E98281CF691' test -only-testing:MangaCartaTests
```

Static verification passed with `git diff --check`.

## Files changed

- `MangaCarta/Services/SourceRegistry.swift`
- `MangaCartaTests/SourceRegistryTests.swift`
- `MangaCarta/Services/UpdateNotifier.swift`
- `MangaCarta/Services/LibraryRefreshCoordinator.swift`
- `MangaCartaTests/UpdateNotifierTests.swift`

## Commits

- `f33e7ab` — `fix(registry): never fall back to a hidden adult Source (ADR-0022 A6)`
- `35543d5` — `fix(updates): keep redacting notifications for mixed Sources (ADR-0022 A6)`

## Self-review and concerns

- `git diff --check` passed.
- The two behavior areas are in separate commits as required.
- No new project file entry was needed; no new test file was added.
- No existing coordinator test asserts adult classification, so the required
  matching coordinator test was not applicable.
- Local unit verification remains pending because CoreSimulatorService was
  unavailable; the controller should run the focused and full unit targets.

## Fix round 1

- Added `import Foundation` to `MangaCartaTests/SourceRegistryTests.swift` so
  the `StubSource.pageURLs` requirement can resolve `URL`.
- Read all five files touched by commits `f33e7ab` and `35543d5`; their imports
  and referenced framework types otherwise appeared compile-ready.
- `git diff --check` passed.

The requested focused test command was attempted once:

```sh
xcodebuild -scheme MangaCarta -destination 'platform=iOS Simulator,id=ADDAB2F8-38C7-4D44-97EA-4E98281CF691' test -only-testing:MangaCartaTests/SourceRegistryTests -only-testing:MangaCartaTests/UpdateNotifierTests
```

It did not reach compilation because the simulator service was unavailable:

```text
CoreSimulatorService connection became invalid. Simulator services will no longer be available.
Error Domain=NSPOSIXErrorDomain Code=61 "Connection refused"
Failed to initialize simulator device set.
```

The controller should run the focused tests.

## Fix round 2

- Restored `firstBrowsable`'s preference for a non-adult Source, falling back to
  an adult Source only while the switch is on, per ADR-0022 A6 point 7.
- Added `fallbackPrefersANonAdultSourceEvenWithTheSwitchOn` to pin the behavior
  with the switch enabled.
- `git diff --check` passed.

The requested simulator tests were not run because the prior CoreSimulatorService
failure already prevented simulator access; no retry was made.

## Fix round 3

- Made `fallbackPrefersANonAdultSourceEvenWithTheSwitchOn` exercise the fallback
  path by setting `registry.activeSourceID = "gone"` before asserting the safe
  Source.
- Saved and restored `UserDefaults.standard["source.activeID"]` in both tests
  that assign `activeSourceID`, preserving the seeded simulator fixture.
- `git diff --check` passed.

The focused `SourceRegistryTests` command was attempted once but did not reach
compilation because CoreSimulatorService returned `Connection refused` while
initializing the requested simulator. No retry was made.
