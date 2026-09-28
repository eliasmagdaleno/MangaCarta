# Task 4 report

## Status

DONE_WITH_CONCERNS. The implementation and tests are complete, but the mandated simulator was unavailable before compilation, so the controller must run the focused and full unit suites.

## Implemented

- Filtered `ExtensionSource` discovery listings and latest updates through `AdultContentFilter.admits`.
- Kept direct listing lookup, detail, chapters, and pages unfiltered.
- Added `ExtensionSource.unfilteredForResolution()` with adult filtering fixed on.
- Added `SourceRegistry.externalIdResolutionSource` and moved only the `MALEntityResolver` composition closure to it.
- Added adult-rating coverage for search, popular, new titles, tag browse, latest updates, mixed/none Sources, and resolution copies.
- Added the ADR-0022 A6 accepted behavior that a fully filtered page ends `PagedMangaLoader`.

## TDD evidence

RED command:

```sh
xcodebuild -scheme MangaCarta -destination 'platform=iOS Simulator,id=ADDAB2F8-38C7-4D44-97EA-4E98281CF691' test -only-testing:MangaCartaTests/AdultListingFilterTests
```

The command did not reach compilation. `CoreSimulatorService connection became invalid`, followed by `Unable to discover any Simulator runtimes` and `Connection refused`; the invocation was stopped after the mandated simulator failed to resolve. The expected pre-implementation compile failure on `unfilteredForResolution` could not be observed in this environment.

GREEN command:

```sh
xcodebuild -scheme MangaCarta -destination 'platform=iOS Simulator,id=ADDAB2F8-38C7-4D44-97EA-4E98281CF691' test -only-testing:MangaCartaTests/AdultListingFilterTests
xcodebuild -scheme MangaCarta -destination 'platform=iOS Simulator,id=ADDAB2F8-38C7-4D44-97EA-4E98281CF691' test -only-testing:MangaCartaTests
```

Not run: the single allowed simulator attempt failed before compilation, and the task instructions prohibit retrying more than once in that condition. No passing test output is available locally.

## Files changed

- `MangaCarta/Models/ExtensionSource.swift`
- `MangaCarta/Services/SourceRegistry.swift`
- `MangaCarta/Services/AppComposition.swift`
- `MangaCartaTests/AdultListingFilterTests.swift`
- `MangaCartaTests/MangaCartaTests.swift`
- `MangaCarta.xcodeproj/project.pbxproj`

## Self-review

`git diff --check` passed. The fixture uses the existing validated listing and update shapes, including optional omission of `contentRating` for the unrated title. Filtering is confined to discovery methods; the resolution copy only changes the adult-setting closure and retains declaration, lifecycle, host, and identity. `AppComposition` leaves reverse resolution, recommendations, and related-title discovery on `externalIdSource` as required. No known Swift 6.0-incompatible syntax was added.

Concern: runtime compilation and unit-test results remain unverified until CoreSimulatorService is available.
