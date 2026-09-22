//
//  ReaderViewModelTests.swift
//  MangaCartaTests
//
//  ADR-0012. The reader was the one screen that never got a view model, which is why
//  none of its loading behaviour was testable. These drive it through a stub
//  `MangaSource` — no network, no simulator timing.
//
//  `testFailedAdvanceLeavesTheChapterBeingReadIntact` is the one that earns the
//  refactor. Load-then-commit's entire value is "on failure, nothing was mutated",
//  and that can only be checked by failing a fetch and inspecting state afterwards.
//  The shipped code mutated first and loaded second, so one 404 chapter mid-series
//  destroyed the chapter the user was on.
//

import XCTest
@testable import MangaCarta

@MainActor
final class ReaderViewModelTests: XCTestCase {

    // MARK: - Fixtures

    private static let manga = Manga(id: "m1", sourceId: "stub", title: "Solo Leveling",
                                     description: "", status: "ongoing", year: nil,
                                     coverURL: nil, malId: nil)

    private static func chapter(_ n: String) -> Chapter {
        Chapter(id: "ch\(n)", number: n, title: nil, date: nil)
    }

    private static let three = [chapter("1"), chapter("2"), chapter("3")]

    private static func urls(_ count: Int) -> [URL] {
        (0..<count).map { URL(string: "https://cdn.test/p\($0).jpg")! }
    }

    /// A source whose `pageURLs` answer is programmable per chapter id, so a single
    /// test can have chapter 2 succeed and chapter 3 fail.
    private final class StubSource: MangaSource {
        let id = "stub"
        let name = "Stub"

        /// chapterId → what `pageURLs` should do.
        var pages: [String: Result<[URL], Error>] = [:]
        var chapterList: [Chapter] = []
        private(set) var chapterFetchCount = 0

        func pageURLs(chapterId: String, preferDataSaver: Bool) async throws -> [URL] {
            switch pages[chapterId] {
            case .success(let urls): return urls
            case .failure(let error): throw error
            case nil: return []
            }
        }

        func chapters(mangaId: String) async throws -> [Chapter] {
            chapterFetchCount += 1
            return chapterList
        }

        func search(title: String, limit: Int, offset: Int) async throws -> [Manga] { [] }
        func popular(limit: Int, offset: Int) async throws -> [Manga] { [] }
        func mangaDetail(id: String) async throws -> MangaDetail {
            throw SourceError.unsupported("mangaDetail")
        }
    }

    /// A source whose fetch for a chosen chapter id *suspends* until the test releases it,
    /// so two advances can be interleaved deterministically — no sleeps, no timing luck.
    ///
    /// ADR-0013: the shipped reader could not be re-entered while loading because clearing
    /// `pages` tore the pager down. Load-then-commit keeps the pager up for the whole fetch,
    /// so a second swipe now reaches an `advance` that has already started.
    ///
    /// **`@MainActor` is load-bearing.** `MangaSource`'s methods are nonisolated, so an
    /// `await source.pageURLs(...)` from the `@MainActor` view model runs off the main actor —
    /// while the test drives `awaitArrival` / `release` on it. Without isolation those two
    /// touch these dictionaries concurrently, which corrupts them: this crashed with
    /// `-[__NSCFNumber objectForKey:]: unrecognized selector` after passing twice. Isolating
    /// the whole stub serializes access and leaves the suspension points — the only places
    /// interleaving is wanted — exactly where they were.
    @MainActor
    private final class GatedSource: MangaSource {
        let id = "stub"
        let name = "Gated"

        var pages: [String: Result<[URL], Error>] = [:]
        /// Chapter ids whose fetch parks until `release(_:)`.
        var gated: Set<String> = []

        private var parked: [String: CheckedContinuation<Void, Never>] = [:]
        private var arrivals: [String: CheckedContinuation<Void, Never>] = [:]
        private var hasArrived: Set<String> = []

        func pageURLs(chapterId: String, preferDataSaver: Bool) async throws -> [URL] {
            if gated.contains(chapterId) {
                await withCheckedContinuation { continuation in
                    parked[chapterId] = continuation
                    hasArrived.insert(chapterId)
                    arrivals.removeValue(forKey: chapterId)?.resume()
                }
            }
            switch pages[chapterId] {
            case .success(let urls): return urls
            case .failure(let error): throw error
            case nil: return []
            }
        }

        /// Suspends until the fetch for `chapterId` has actually been entered and parked.
        func awaitArrival(_ chapterId: String) async {
            guard !hasArrived.contains(chapterId) else { return }
            await withCheckedContinuation { arrivals[chapterId] = $0 }
        }

        func release(_ chapterId: String) {
            parked.removeValue(forKey: chapterId)?.resume()
        }

        func chapters(mangaId: String) async throws -> [Chapter] { [] }
        func search(title: String, limit: Int, offset: Int) async throws -> [Manga] { [] }
        func popular(limit: Int, offset: Int) async throws -> [Manga] { [] }
        func mangaDetail(id: String) async throws -> MangaDetail {
            throw SourceError.unsupported("mangaDetail")
        }
    }

    private func makeGatedVM(chapter: Chapter,
                             configure: (GatedSource) -> Void) -> (ReaderViewModel, GatedSource) {
        let source = GatedSource()
        configure(source)
        let vm = ReaderViewModel(manga: Self.manga, chapter: chapter, chapters: Self.three,
                                 initialPosition: ReadingPosition(page: 0), source: source,
                                 prefetch: { _, _ in })
        return (vm, source)
    }

    private func makeVM(chapter: Chapter,
                        chapters: [Chapter] = ReaderViewModelTests.three,
                        initialPosition: ReadingPosition = ReadingPosition(page: 0),
                        configure: (StubSource) -> Void) -> (ReaderViewModel, StubSource) {
        let source = StubSource()
        configure(source)
        // Swallow the prefetch: these tests must not touch the network or the real cache.
        let vm = ReaderViewModel(manga: Self.manga, chapter: chapter, chapters: chapters,
                                 initialPosition: initialPosition, source: source,
                                 prefetch: { _, _ in })
        return (vm, source)
    }

    // MARK: - Initial load

    func testSuccessfulLoadPopulatesPagesAndClearsError() async {
        let (vm, _) = makeVM(chapter: Self.chapter("1")) {
            $0.pages["ch1"] = .success(Self.urls(20))
        }
        await vm.begin()

        XCTAssertEqual(vm.pages.count, 20)
        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(vm.presentation.body, .content)
        XCTAssertFalse(vm.presentation.chromeForced)
    }

    /// The reported bug's trigger. A 404 must leave the reader escapable, which means
    /// chrome forced, and must not offer a Retry that cannot work.
    func testNotFoundIsAPermanentFullScreenErrorWithChromeForced() async {
        let (vm, _) = makeVM(chapter: Self.chapter("1")) {
            $0.pages["ch1"] = .failure(MangaDexError.httpStatus(404))
        }
        await vm.begin()

        XCTAssertTrue(vm.pages.isEmpty)
        XCTAssertTrue(vm.presentation.chromeForced, "a failed load must stay escapable")
        XCTAssertEqual(vm.presentation.body,
                       .error(message: readerFailureMessage(MangaDexError.httpStatus(404)),
                              canRetry: false))
    }

    func testTransientFailureKeepsRetryAvailable() async {
        let (vm, _) = makeVM(chapter: Self.chapter("1")) {
            $0.pages["ch1"] = .failure(URLError(.notConnectedToInternet))
        }
        await vm.begin()

        guard case .error(_, let canRetry) = vm.presentation.body else {
            return XCTFail("expected an error body, got \(vm.presentation.body)")
        }
        XCTAssertTrue(canRetry)
    }

    /// Both sources `compactMap` their page lists and can return `[]` without throwing
    /// (`MangaDexAPI.swift:591`, `bundled WeebCentral Source.swift:87`). That used to render a
    /// blank screen with no message at all.
    func testEmptyPageListBecomesAPermanentErrorRatherThanABlankScreen() async {
        let (vm, _) = makeVM(chapter: Self.chapter("1")) {
            $0.pages["ch1"] = .success([])
        }
        await vm.begin()

        XCTAssertTrue(vm.presentation.chromeForced)
        guard case .error(let message, let canRetry) = vm.presentation.body else {
            return XCTFail("expected an error body, got \(vm.presentation.body)")
        }
        XCTAssertFalse(canRetry, "no amount of retrying adds pages to an empty chapter")
        XCTAssertFalse(message.isEmpty)
    }

    func testRetryAfterATransientFailureRecovers() async {
        let (vm, source) = makeVM(chapter: Self.chapter("1")) {
            $0.pages["ch1"] = .failure(URLError(.timedOut))
        }
        await vm.begin()
        XCTAssertTrue(vm.pages.isEmpty)

        source.pages["ch1"] = .success(Self.urls(5))
        await vm.retry()

        XCTAssertEqual(vm.pages.count, 5)
        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(vm.presentation.body, .content)
    }

    func testChaptersAreFetchedOnlyWhenNotSupplied() async {
        let (supplied, suppliedSource) = makeVM(chapter: Self.chapter("1")) {
            $0.pages["ch1"] = .success(Self.urls(3))
        }
        await supplied.begin()
        XCTAssertEqual(suppliedSource.chapterFetchCount, 0, "chapters were passed in")

        let (bare, bareSource) = makeVM(chapter: Self.chapter("1"), chapters: []) {
            $0.pages["ch1"] = .success(Self.urls(3))
            $0.chapterList = Self.three
        }
        await bare.begin()
        XCTAssertEqual(bareSource.chapterFetchCount, 1)
        XCTAssertEqual(bare.chapters.count, 3)
    }

    // MARK: - Pager target

    func testInitialPageIsClampedToTheChapterLength() async {
        let (vm, _) = makeVM(chapter: Self.chapter("1"), initialPosition: ReadingPosition(page: 999)) {
            $0.pages["ch1"] = .success(Self.urls(10))
        }
        await vm.begin()
        XCTAssertEqual(vm.pagerTarget, ReadingPosition(page: 9))
    }

    /// A fraction is only meaningful against the page it was captured on. When the clamp
    /// *moves* the page — the chapter was re-uploaded with fewer, re-cut pages — 60% down
    /// strip 7 maps to nothing, so the reader lands at the top of the page that exists
    /// rather than at a plausible-looking wrong place (ADR-0014 decision 4's amendment).
    func testAClampedPositionLosesItsFraction() async {
        let (vm, _) = makeVM(chapter: Self.chapter("1"),
                             initialPosition: ReadingPosition(page: 7, fraction: 0.6)) {
            $0.pages["ch1"] = .success(Self.urls(5))
        }
        await vm.begin()

        XCTAssertEqual(vm.pagerTarget, ReadingPosition(page: 4),
                       "clamped to the last page, and the fraction goes with the page it belonged to")
    }

    /// The other half of the rule: a page that survives the clamp keeps its fraction, which
    /// is the whole point of carrying one.
    func testAnUnclampedPositionKeepsItsFraction() async {
        let (vm, _) = makeVM(chapter: Self.chapter("1"),
                             initialPosition: ReadingPosition(page: 3, fraction: 0.6)) {
            $0.pages["ch1"] = .success(Self.urls(10))
        }
        await vm.begin()

        XCTAssertEqual(vm.pagerTarget, ReadingPosition(page: 3, fraction: 0.6))
    }

    func testMovingBackwardsLandsOnTheLastPage() async {
        let (vm, _) = makeVM(chapter: Self.chapter("2")) {
            $0.pages["ch2"] = .success(Self.urls(8))
            $0.pages["ch1"] = .success(Self.urls(12))
        }
        await vm.begin()
        await vm.loadPrevious()

        XCTAssertEqual(vm.currentChapter.id, "ch1")
        XCTAssertEqual(vm.pagerTarget, ReadingPosition(page: 11),
                       "entering a chapter backwards opens at its end")
    }

    /// ADR-0013. A failed *forward* advance leaves the pager on the sentinel index that
    /// requested the chapter, which renders nothing at all. The target retreats into the
    /// chapter that survived, so the user lands on the page they were reading.
    func testAFailedForwardAdvanceRetreatsToTheLastRealPage() async {
        let (vm, _) = makeVM(chapter: Self.chapter("2")) {
            $0.pages["ch2"] = .success(Self.urls(20))
            $0.pages["ch3"] = .failure(MangaDexError.httpStatus(404))
        }
        await vm.begin()
        await vm.loadNext()

        XCTAssertEqual(vm.pagerTarget, ReadingPosition(page: 19),
                       "the last page of the chapter that survived")
    }

    func testAFailedBackwardAdvanceRetreatsToTheFirstPage() async {
        let (vm, _) = makeVM(chapter: Self.chapter("2")) {
            $0.pages["ch2"] = .success(Self.urls(20))
            $0.pages["ch1"] = .failure(MangaDexError.httpStatus(404))
        }
        await vm.begin()
        await vm.loadPrevious()

        XCTAssertEqual(vm.pagerTarget, ReadingPosition(page: 0))
    }

    /// A failed initial load has nothing to retreat into, so the target is left alone.
    func testAFailedInitialLoadLeavesTheTargetAlone() async {
        let (vm, _) = makeVM(chapter: Self.chapter("1"), initialPosition: ReadingPosition(page: 4)) {
            $0.pages["ch1"] = .failure(MangaDexError.httpStatus(404))
        }
        await vm.begin()

        XCTAssertEqual(vm.pagerTarget, ReadingPosition(page: 0))
    }

    // MARK: - Completion marker

    /// The view repositions the pager on this marker rather than on `pagerTarget`'s value,
    /// because consecutive chapters both landing on page 0 is the *common* case and an
    /// unchanged value fires no `onChange` — leaving the pager on a stale sentinel index
    /// that immediately re-requests the next chapter.
    func testTheCompletionMarkerAdvancesOnEveryFinishedLoad() async {
        let (vm, _) = makeVM(chapter: Self.chapter("1")) {
            $0.pages["ch1"] = .success(Self.urls(10))
            $0.pages["ch2"] = .success(Self.urls(10))
            $0.pages["ch3"] = .failure(MangaDexError.httpStatus(404))
        }
        XCTAssertEqual(vm.lastCompletedRequest, 0, "nothing has completed yet")

        await vm.begin()
        let afterBegin = vm.lastCompletedRequest
        XCTAssertGreaterThan(afterBegin, 0)

        await vm.loadNext()
        let afterAdvance = vm.lastCompletedRequest
        XCTAssertGreaterThan(afterAdvance, afterBegin)
        XCTAssertEqual(vm.pagerTarget, ReadingPosition(page: 0),
                       "two consecutive chapters landing on the same page")

        await vm.loadNext()   // ch3 fails
        XCTAssertGreaterThan(vm.lastCompletedRequest, afterAdvance,
                             "a failure completes too — the pager still has to move")
    }

    // MARK: - Failure copy

    /// Bare `localizedDescription` is fine full-screen and useless in a banner: the user
    /// swipes forward, is snapped back, and reads a sentence with no subject.
    func testAFailedAdvanceNamesTheDirection() async {
        let (vm, _) = makeVM(chapter: Self.chapter("2")) {
            $0.pages["ch2"] = .success(Self.urls(20))
            $0.pages["ch3"] = .failure(MangaDexError.httpStatus(404))
            $0.pages["ch1"] = .failure(MangaDexError.httpStatus(404))
        }
        await vm.begin()

        await vm.loadNext()
        XCTAssertEqual(vm.presentation.banner?.hasPrefix("Couldn't load the next chapter."), true,
                       "got: \(vm.presentation.banner ?? "nil")")

        await vm.loadPrevious()
        XCTAssertEqual(vm.presentation.banner?.hasPrefix("Couldn't load the previous chapter."), true,
                       "got: \(vm.presentation.banner ?? "nil")")
    }

    /// The initial load and a retry render full-screen, where the subject is unambiguous,
    /// so they carry no prefix.
    func testAFailedInitialLoadCarriesNoDirectionPrefix() async {
        let (vm, _) = makeVM(chapter: Self.chapter("1")) {
            $0.pages["ch1"] = .failure(MangaDexError.httpStatus(404))
        }
        await vm.begin()

        XCTAssertEqual(vm.errorMessage, readerFailureMessage(MangaDexError.httpStatus(404)))
    }

    /// The failed chapter's reason still has to reach the user, prefix or not.
    func testTheDirectionPrefixKeepsTheUnderlyingReason() async {
        let (vm, _) = makeVM(chapter: Self.chapter("2")) {
            $0.pages["ch2"] = .success(Self.urls(20))
            $0.pages["ch3"] = .success([])          // empty list ⇒ ReaderError.noPages
        }
        await vm.begin()
        await vm.loadNext()

        let banner = vm.presentation.banner ?? ""
        XCTAssertTrue(banner.contains("Couldn't load the next chapter."))
        XCTAssertTrue(banner.contains(ReaderError.noPages.localizedDescription))
    }

    // MARK: - Load-then-commit

    /// The decision this refactor exists for. Chapter 3 is a 404; chapter 2 must survive
    /// intact — same chapter, same pages — so the user keeps reading instead of being
    /// ejected from the series.
    func testFailedAdvanceLeavesTheChapterBeingReadIntact() async {
        let (vm, _) = makeVM(chapter: Self.chapter("2")) {
            $0.pages["ch2"] = .success(Self.urls(20))
            $0.pages["ch3"] = .failure(MangaDexError.httpStatus(404))
        }
        await vm.begin()
        let pagesBefore = vm.pages

        await vm.loadNext()

        XCTAssertEqual(vm.currentChapter.id, "ch2", "a failed advance must not move the chapter")
        XCTAssertEqual(vm.pages, pagesBefore, "a failed advance must not discard loaded pages")
    }

    /// ...and the failure still has to be *told* to the user — over the content, not
    /// instead of it.
    func testFailedAdvanceBannersTheErrorWithoutBlankingTheChapter() async {
        let (vm, _) = makeVM(chapter: Self.chapter("2")) {
            $0.pages["ch2"] = .success(Self.urls(20))
            $0.pages["ch3"] = .failure(MangaDexError.httpStatus(404))
        }
        await vm.begin()
        await vm.loadNext()

        XCTAssertEqual(vm.presentation.body, .content)
        XCTAssertNotNil(vm.presentation.banner)
        XCTAssertFalse(vm.presentation.chromeForced, "pages are still on screen")
    }

    func testSuccessfulAdvanceCommitsTheNewChapter() async {
        let (vm, _) = makeVM(chapter: Self.chapter("2")) {
            $0.pages["ch2"] = .success(Self.urls(20))
            $0.pages["ch3"] = .success(Self.urls(14))
        }
        await vm.begin()
        await vm.loadNext()

        XCTAssertEqual(vm.currentChapter.id, "ch3")
        XCTAssertEqual(vm.pages.count, 14)
        XCTAssertEqual(vm.pagerTarget, ReadingPosition(page: 0))
        XCTAssertNil(vm.errorMessage)
        XCTAssertNil(vm.presentation.banner)
    }

    /// A stale banner from a failed advance must not outlive a successful one.
    func testASuccessfulAdvanceClearsAPreviousFailure() async {
        let (vm, source) = makeVM(chapter: Self.chapter("2")) {
            $0.pages["ch2"] = .success(Self.urls(20))
            $0.pages["ch3"] = .failure(MangaDexError.httpStatus(404))
        }
        await vm.begin()
        await vm.loadNext()
        XCTAssertNotNil(vm.presentation.banner)

        source.pages["ch3"] = .success(Self.urls(9))
        await vm.loadNext()

        XCTAssertEqual(vm.currentChapter.id, "ch3")
        XCTAssertNil(vm.presentation.banner)
    }

    func testAdvancingPastTheLastChapterDoesNothing() async {
        let (vm, _) = makeVM(chapter: Self.chapter("3")) {
            $0.pages["ch3"] = .success(Self.urls(6))
        }
        await vm.begin()
        await vm.loadNext()

        XCTAssertEqual(vm.currentChapter.id, "ch3")
        XCTAssertEqual(vm.pages.count, 6)
        XCTAssertNil(vm.errorMessage)
    }

    // MARK: - Two advances at once (ADR-0013)

    /// The user swipes forward, the fetch is slow, they swipe back before it returns. Both
    /// requests are in flight and both would otherwise commit in whatever order the network
    /// answers — so the user can land on the chapter they asked for *first*.
    func testASupersededAdvanceCommitsNothing() async {
        let (vm, source) = makeGatedVM(chapter: Self.chapter("2")) {
            $0.pages["ch2"] = .success(Self.urls(20))
            $0.pages["ch3"] = .success(Self.urls(14))
            $0.pages["ch1"] = .success(Self.urls(7))
            $0.gated = ["ch3"]
        }
        await vm.begin()

        let forward = Task { await vm.loadNext() }
        await source.awaitArrival("ch3")        // the forward fetch is genuinely in flight

        await vm.loadPrevious()                 // supersedes it, and commits
        XCTAssertEqual(vm.currentChapter.id, "ch1")

        source.release("ch3")
        await forward.value

        XCTAssertEqual(vm.currentChapter.id, "ch1", "the newest request must win")
        XCTAssertEqual(vm.pages.count, 7)
        XCTAssertEqual(vm.pagerTarget, ReadingPosition(page: 6),
                       "the target belongs to the request that won")
    }

    /// A superseded request that *fails* must stay silent: a banner about a chapter the user
    /// has already navigated away from explains nothing.
    func testASupersededFailureRaisesNoBanner() async {
        let (vm, source) = makeGatedVM(chapter: Self.chapter("2")) {
            $0.pages["ch2"] = .success(Self.urls(20))
            $0.pages["ch3"] = .failure(MangaDexError.httpStatus(404))
            $0.pages["ch1"] = .success(Self.urls(7))
            $0.gated = ["ch3"]
        }
        await vm.begin()

        let forward = Task { await vm.loadNext() }
        await source.awaitArrival("ch3")

        await vm.loadPrevious()
        source.release("ch3")
        await forward.value

        XCTAssertNil(vm.presentation.banner, "the failure was superseded before it landed")
        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(vm.currentChapter.id, "ch1")
    }

    /// `defer { isLoading = false }` as shipped lets whichever request finishes first clear
    /// the flag out from under one that is still running — so the spinner vanishes while a
    /// chapter is still loading.
    func testASupersededRequestDoesNotClearTheLoadingFlag() async {
        let (vm, source) = makeGatedVM(chapter: Self.chapter("2")) {
            $0.pages["ch2"] = .success(Self.urls(20))
            $0.pages["ch3"] = .success(Self.urls(14))
            $0.pages["ch1"] = .success(Self.urls(7))
            $0.gated = ["ch3", "ch1"]
        }
        await vm.begin()

        let forward = Task { await vm.loadNext() }
        await source.awaitArrival("ch3")
        let backward = Task { await vm.loadPrevious() }
        await source.awaitArrival("ch1")

        source.release("ch3")                   // the superseded one finishes first
        await forward.value
        XCTAssertTrue(vm.isLoading, "the newer request is still running")

        source.release("ch1")
        await backward.value
        XCTAssertFalse(vm.isLoading)
        XCTAssertEqual(vm.currentChapter.id, "ch1")
    }

    /// ...and a superseded request must not bump the completion marker either, or the view
    /// repositions the pager for a load whose result was thrown away.
    func testASupersededRequestDoesNotBumpTheCompletionMarker() async {
        let (vm, source) = makeGatedVM(chapter: Self.chapter("2")) {
            $0.pages["ch2"] = .success(Self.urls(20))
            $0.pages["ch3"] = .success(Self.urls(14))
            $0.pages["ch1"] = .success(Self.urls(7))
            $0.gated = ["ch3"]
        }
        await vm.begin()

        let forward = Task { await vm.loadNext() }
        await source.awaitArrival("ch3")

        await vm.loadPrevious()
        let afterWinner = vm.lastCompletedRequest

        source.release("ch3")
        await forward.value

        XCTAssertEqual(vm.lastCompletedRequest, afterWinner)
    }
}
