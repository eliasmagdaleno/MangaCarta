//
//  ReaderPresentationTests.swift
//  MangaCartaTests
//
//  ADR-0012. `ReaderPresentation` is a pure function of four scalars, so the state
//  space is small enough to walk exhaustively — which is the point. The bug this
//  type exists to prevent was not a wrong branch but two branches that were allowed
//  to disagree: "which body do we show" and "can the user leave" were independent
//  decisions, so a state existed where the exit was unreachable.
//
//  `testChromeIsForcedWheneverThereIsNothingToRead` is therefore the load-bearing
//  test. It asserts the invariant over every input combination rather than over the
//  three states we happen to have thought of, so a fourth state added later cannot
//  reintroduce the trap without going red.
//

import XCTest
@testable import MangaCarta

final class ReaderPresentationTests: XCTestCase {

    // MARK: - The invariant

    /// The trap in one line: if there is no page on screen, the chrome — and with it
    /// the only dismiss control — must be visible. Walked exhaustively over the whole
    /// input space, so this holds for states that do not exist yet.
    func testChromeIsForcedWheneverThereIsNothingToRead() {
        for message in [nil, "boom"] as [String?] {
            for isTransient in [true, false] {
                for isLoading in [true, false] {
                    let p = ReaderPresentation(errorMessage: message,
                                               isTransient: isTransient,
                                               isLoading: isLoading,
                                               pageCount: 0)
                    XCTAssertTrue(p.chromeForced,
                                  "no pages ⇒ chrome must be forced " +
                                  "(message: \(message ?? "nil"), transient: \(isTransient), loading: \(isLoading))")
                }
            }
        }
    }

    /// The converse: once there are pages, chrome goes back to being the user's own
    /// toggle. Forcing it forever would defeat full-bleed reading.
    func testChromeIsNotForcedOncePagesExist() {
        for message in [nil, "boom"] as [String?] {
            for isLoading in [true, false] {
                let p = ReaderPresentation(errorMessage: message,
                                           isTransient: true,
                                           isLoading: isLoading,
                                           pageCount: 12)
                XCTAssertFalse(p.chromeForced)
            }
        }
    }

    // MARK: - Body selection

    func testErrorWithNoPagesTakesTheWholeScreen() {
        let p = ReaderPresentation(errorMessage: "Request failed with HTTP status 404.",
                                   isTransient: false, isLoading: false, pageCount: 0)
        XCTAssertEqual(p.body, .error(message: "Request failed with HTTP status 404.", canRetry: false))
        XCTAssertNil(p.banner, "a full-screen error must not also raise a banner")
    }

    /// A transient failure keeps Retry; a permanent one must not offer it. Pressing a
    /// button that cannot succeed is what made the reported bug feel like a trap.
    func testRetryIsOfferedOnlyForTransientFailures() {
        let transient = ReaderPresentation(errorMessage: "offline",
                                           isTransient: true, isLoading: false, pageCount: 0)
        XCTAssertEqual(transient.body, .error(message: "offline", canRetry: true))

        let permanent = ReaderPresentation(errorMessage: "gone",
                                           isTransient: false, isLoading: false, pageCount: 0)
        XCTAssertEqual(permanent.body, .error(message: "gone", canRetry: false))
    }

    func testLoadingWithNoPagesShowsTheLoadingState() {
        let p = ReaderPresentation(errorMessage: nil, isTransient: true,
                                   isLoading: true, pageCount: 0)
        XCTAssertEqual(p.body, .loading)
    }

    /// An error raised while a chapter is still readable must not blank it out — that
    /// is the whole point of load-then-commit. It surfaces as a banner over the content.
    func testFailedAdvanceKeepsTheReadableChapterAndBannersTheError() {
        let p = ReaderPresentation(errorMessage: "Chapter 7 is unavailable.",
                                   isTransient: false, isLoading: false, pageCount: 20)
        XCTAssertEqual(p.body, .content)
        XCTAssertEqual(p.banner, "Chapter 7 is unavailable.")
    }

    /// Loading the *next* chapter must not replace the one being read.
    func testLoadingWithPagesKeepsShowingContent() {
        let p = ReaderPresentation(errorMessage: nil, isTransient: true,
                                   isLoading: true, pageCount: 20)
        XCTAssertEqual(p.body, .content)
        XCTAssertNil(p.banner)
    }

    func testHealthyChapterShowsContentWithNoBanner() {
        let p = ReaderPresentation(errorMessage: nil, isTransient: true,
                                   isLoading: false, pageCount: 20)
        XCTAssertEqual(p.body, .content)
        XCTAssertNil(p.banner)
        XCTAssertFalse(p.chromeForced)
    }

    /// An error outranks loading when neither has anything to show: a retry that is
    /// already in flight must not hide the message that explains why.
    func testErrorOutranksLoadingWhenBothApply() {
        let p = ReaderPresentation(errorMessage: "boom", isTransient: true,
                                   isLoading: true, pageCount: 0)
        XCTAssertEqual(p.body, .error(message: "boom", canRetry: true))
    }

    // MARK: - Failure classification

    /// Network failures are the case where withholding Retry would be worst — the user
    /// did nothing wrong and the next attempt may well work.
    func testNetworkFailuresAreTransient() {
        XCTAssertTrue(isTransientFailure(URLError(.notConnectedToInternet)))
        XCTAssertTrue(isTransientFailure(URLError(.timedOut)))
    }

    /// An unrecognised error is transient, matching `permanentStatus`'s `default: return nil`.
    /// Costs a wasted tap when wrong; withholding Retry when wrong strands the user.
    func testUnknownErrorsDefaultToTransient() {
        struct Mystery: Error {}
        XCTAssertTrue(isTransientFailure(Mystery()))
    }

    func testSourceErrorsClassifyByWhetherRetryCouldHelp() {
        // The scraper's script stopped matching the page — pressing a button won't fix it.
        XCTAssertFalse(isTransientFailure(SourceError.extractionFailed("no images found")))
        XCTAssertFalse(isTransientFailure(SourceError.unsupported("pageURLs")))
        // A dismissed Cloudflare challenge is re-presented on retry, so retry is exactly right.
        XCTAssertTrue(isTransientFailure(SourceError.cloudflareUnsolved))
        XCTAssertTrue(isTransientFailure(SourceError.navigationFailed("connection lost")))
    }

    func testExtensionPermanentCodesAreNotTransient() {
        let codes: [ExtensionHostErrorCode] = [.invalidRequest, .invalidResponse,
                                                .invalidResult, .unsupported,
                                                .unsupportedLanguage, .policyDenied,
                                                .incompatibleVersion, .script]
        for code in codes {
            XCTAssertFalse(isTransientFailure(ExtensionSourceError.invocation(code)), "\(code)")
        }
    }

    func testExtensionTransientCodesAreTransient() {
        let codes: [ExtensionHostErrorCode] = [.cancelled, .network, .navigation, .timeout,
                                                .rateLimited, .interactionRequired,
                                                .interactionDeclined, .interactionTimedOut,
                                                .storage, .resourceLimit, .http]
        for code in codes {
            XCTAssertTrue(isTransientFailure(ExtensionSourceError.invocation(code)), "\(code)")
        }
    }

    func testExtensionNonInvocationCasesAreTransient() {
        XCTAssertTrue(isTransientFailure(ExtensionSourceError.unavailable(name: "Echo")))
        XCTAssertTrue(isTransientFailure(ExtensionSourceError.rateLimited(retryAfterSeconds: nil)))
        XCTAssertTrue(isTransientFailure(ExtensionSourceError.pageOutOfSequence))
    }

    func testExtensionHTTPStatusClassification() {
        for status in [404, 403, 410, 400] {
            XCTAssertFalse(isTransientFailure(ExtensionSourceError.http(status: status)), "\(status)")
        }
        for status in [408, 429, 500, 503] {
            XCTAssertTrue(isTransientFailure(ExtensionSourceError.http(status: status)), "\(status)")
        }
        XCTAssertTrue(isTransientFailure(ExtensionSourceError.http(status: nil)))
    }

    // MARK: - Failure copy (ADR-0013)

    /// Every error type the reader can see already reads as English, so the reader must not
    /// paraphrase it — `SourceError` and `ReaderError` messages pass through untouched.
    func testEveryErrorPassesThroughUnchanged() {
        for error in [SourceError.cloudflareUnsolved,
                      SourceError.extractionFailed("no images found")] as [Error] {
            XCTAssertEqual(readerFailureMessage(error), error.localizedDescription)
        }
        XCTAssertEqual(readerFailureMessage(ReaderError.noPages),
                       ReaderError.noPages.localizedDescription)

        struct Mystery: Error {}
        XCTAssertEqual(readerFailureMessage(Mystery()), Mystery().localizedDescription)
    }

    // MARK: - What the reader says out loud (issue #90)

    /// The load-bearing one: wherever the reader shows a page, it must be able to say
    /// which page of how many. Right-to-left reverses the pager's order, so a swipe that
    /// announces nothing leaves no way to tell forward from backward.
    func testEveryPageSaysWhichPageOfHowMany() {
        for pageCount in 1...5 {
            for index in 0..<pageCount {
                let label = ReaderAccessibility.pageLabel(index: index, pageCount: pageCount)
                XCTAssertEqual(label, "Page \(index + 1) of \(pageCount)")
            }
        }
    }

    /// Page numbers are 1-based to the ear even though the view holds them 0-based.
    func testPageLabelIsOneBased() {
        XCTAssertEqual(ReaderAccessibility.pageLabel(index: 0, pageCount: 20), "Page 1 of 20")
    }

    /// A page can exist before the count does — the label degrades rather than saying "of 0".
    func testPageLabelWithoutACountOmitsTheTotal() {
        XCTAssertEqual(ReaderAccessibility.pageLabel(index: 3, pageCount: 0), "Page 4")
    }

    func testIndicatorSaysTheSameSentenceAsThePage() {
        XCTAssertEqual(ReaderAccessibility.pageIndicatorLabel(currentPage: 3, pageCount: 20),
                       ReaderAccessibility.pageLabel(index: 3, pageCount: 20))
    }

    /// The pager's extra indices (chapter-advance triggers) fall outside the page range,
    /// exactly as the visible indicator already clamps them.
    func testIndicatorClampsOutOfRangePages() {
        XCTAssertEqual(ReaderAccessibility.pageIndicatorLabel(currentPage: -3, pageCount: 20),
                       "Page 1 of 20")
        XCTAssertEqual(ReaderAccessibility.pageIndicatorLabel(currentPage: 40, pageCount: 20),
                       "Page 20 of 20")
    }

    /// None of the spoken strings may carry the typography they replace.
    func testNoSpokenStringContainsTheMiddleDot() {
        let chapter = Chapter(id: "c", number: "12", title: "Blood and Ink", date: nil)
        let strings = [ReaderAccessibility.pageLabel(index: 3, pageCount: 20),
                       ReaderAccessibility.pageIndicatorLabel(currentPage: 3, pageCount: 20),
                       ReaderAccessibility.endMarkLabel(pageCount: 20),
                       ReaderAccessibility.interstitialLabel(chapter: chapter, isNext: true,
                                                             isLoading: false)]
        for string in strings {
            XCTAssertFalse(string.contains("\u{00B7}"), string)
        }
    }

    func testEndMarkReadsAsASentence() {
        XCTAssertEqual(ReaderAccessibility.endMarkLabel(pageCount: 20), "End of chapter. 20 pages")
    }

    func testEndMarkSingularPage() {
        XCTAssertEqual(ReaderAccessibility.endMarkLabel(pageCount: 1), "End of chapter. 1 page")
    }

    func testInterstitialNamesTheDirectionAndTheChapter() {
        let chapter = Chapter(id: "c", number: "13", title: "Blood and Ink", date: nil)
        XCTAssertEqual(ReaderAccessibility.interstitialLabel(chapter: chapter, isNext: true,
                                                             isLoading: false),
                       "Next chapter, Chapter 13, Blood and Ink")
        XCTAssertEqual(ReaderAccessibility.interstitialLabel(chapter: chapter, isNext: false,
                                                             isLoading: false),
                       "Previous chapter, Chapter 13, Blood and Ink")
    }

    /// While it is a load trigger the interstitial is the whole screen, so the fetch has
    /// to be audible — otherwise the wait is silent (checklist 6.7).
    func testInterstitialAnnouncesAnInFlightFetch() {
        let chapter = Chapter(id: "c", number: "13", title: nil, date: nil)
        XCTAssertEqual(ReaderAccessibility.interstitialLabel(chapter: chapter, isNext: true,
                                                             isLoading: true),
                       "Next chapter, Chapter 13, Fetching pages")
    }
}
