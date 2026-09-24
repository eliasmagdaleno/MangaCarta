//
//  ReaderPresentation.swift
//  MangaCarta
//
//  ADR-0012. Two small pieces the reader needs and nothing else owns:
//
//    • `isTransientFailure` — is retrying worth offering? Permanent failures get a
//      way out instead of a button that cannot work.
//    • `ReaderPresentation` — the whole state → screen decision as one pure value.
//
//  The second exists because the reader once let two decisions disagree: "which body
//  do we show" and "can the user leave" were separate branches, and a 404 landed in a
//  state where the error filled the screen and the dismiss control was unreachable.
//  Deciding both here, from the same inputs, makes that combination unrepresentable
//  rather than merely avoided.
//

import Foundation

// MARK: - Failure classification

/// An error that knows whether retrying could plausibly succeed.
///
/// The reader reaches sources through `MangaSource`, so it sees `MangaDexError` from
/// one and `SourceError` from another and cannot switch on either concrete type.
protocol ClassifiedFailure {
    /// `true` when the failure might resolve on its own — an outage, a timeout, a
    /// throttle. `false` when it is an *answer*: the thing asked for is not there.
    var isTransient: Bool { get }
}

/// Whether `error` is worth retrying. **Anything unrecognised is transient.**
///
/// This mirrors `MetadataUpgradeQueue.permanentStatus(of:)`, whose `default: return nil`
/// makes the same call, and the asymmetry justifies it either way: wrongly offering
/// Retry costs a wasted tap, while wrongly withholding it strands a user whose network
/// blipped. A bridged extension source (ADR-0003) cannot conform to a Swift protocol,
/// so it lands here by construction — the right default for a source we know nothing about.
func isTransientFailure(_ error: Error) -> Bool {
    (error as? ClassifiedFailure)?.isTransient ?? true
}

/// What to *tell the user* about `error`. ADR-0013.
///
/// Almost every error the reader can see already reads as English — `SourceError`'s cases
/// and `ReaderError.noPages` are plain sentences. `MangaDexError.httpStatus` is the one
/// exception ("Request failed with HTTP status 404.", `MangaDexAPI.swift:349`), and it is
/// the exact string the field report was about.
///
/// **The code stays in the sentence.** ADR-0012's first hazard is that MangaDex answers 404
/// from `/at-home/server` for an *externally hosted* chapter as well as a missing one, so the
/// copy can only claim the chapter is not available *here* — and when this shows up in the
/// field the code is what distinguishes the two.
///
/// `MangaDexError.errorDescription` itself is deliberately left alone: those strings also
/// surface on Home, Detail, Search and More Like This.
func readerFailureMessage(_ error: Error) -> String {
    if case .httpStatus(let code)? = error as? MangaDexError {
        return "This chapter isn't available to read from this source. (HTTP \(code))"
    }
    return error.localizedDescription
}

extension MangaDexError: ClassifiedFailure {
    var isTransient: Bool {
        switch self {
        case .rateLimited:
            return true
        case .invalidResponse:
            return true                 // Malformed reply; the next one may be fine.
        case .invalidURL:
            return false                // We built a bad URL. Retrying rebuilds the same one.
        case .httpStatus(let code):
            // 4xx is the server answering "no". The two exceptions mean "not now":
            // 429 (throttled) matches the upgrade queue; 408 (timeout) is ADR-0012's
            // deliberate divergence from it, because the reader talks to an image CDN
            // where a timeout is plausible and MAL/AniList never emit one.
            guard (400..<500).contains(code) else { return true }
            return code == 429 || code == 408
        }
    }
}

extension SourceError: ClassifiedFailure {
    var isTransient: Bool {
        switch self {
        case .unavailable:
            return true                 // A Source may be installed later.
        case .unsupported:
            return false                // The capability does not exist. It will not appear.
        case .extractionFailed:
            return false                // The scraper's script stopped matching the page.
        case .cloudflareUnsolved:
            return true                 // Retry re-presents the challenge, which is the fix.
        case .navigationFailed:
            return true                 // The page did not load; it may next time.
        }
    }
}

// MARK: - Presentation

/// What the reader should put on screen, and whether the user can get out.
///
/// A pure function of four scalars, so `ReaderPresentationTests` walks the input space
/// exhaustively — including the invariant that carries this type's reason for existing:
/// **no pages ⇒ chrome forced**.
struct ReaderPresentation: Equatable {

    enum Body: Equatable {
        /// Nothing readable behind it. `canRetry` is false for permanent failures, where
        /// the offered action is to leave rather than to try again.
        case error(message: String, canRetry: Bool)
        case loading
        case content
    }

    let body: Body

    /// Forces the chrome — and with it the only dismiss control — visible regardless of
    /// the user's own toggle. True exactly when there is no page on screen, so every
    /// state that cannot be read out of can still be left.
    let chromeForced: Bool

    /// A failure to surface *over* readable content. Non-nil only when a chapter advance
    /// failed while the previous chapter was still loaded (ADR-0012's load-then-commit):
    /// blanking out a chapter the user is reading to report that a different one is
    /// missing is the opposite of what that decision is for.
    let banner: String?

    init(errorMessage: String?, isTransient: Bool, isLoading: Bool, pageCount: Int) {
        let hasPages = pageCount > 0
        chromeForced = !hasPages

        if let errorMessage, !hasPages {
            // An error outranks a retry already in flight: hiding the message behind a
            // spinner would leave the user with no idea why they are waiting.
            body = .error(message: errorMessage, canRetry: isTransient)
            banner = nil
        } else if isLoading, !hasPages {
            body = .loading
            banner = nil
        } else {
            body = .content
            banner = errorMessage
        }
    }
}

// MARK: - What the reader says out loud

/// The reader's spoken strings, apart from the view that shows them.
///
/// Issue #90, checklist rows 6.4 / 6.5 / 6.7 / 6.10. The reader was built to be read with
/// the eyes: its page indicator is `"4 · 20"`, its chapter end is `"END · 20 PAGES"`, and
/// its pages were bare images with no label at all. A middle dot is not a word and an
/// unlabelled image is not a destination, so VoiceOver had no way to say where in a
/// chapter it was — in the paged mode, the pages may not have been reachable at all.
///
/// These are pure functions of the same numbers the view already has, so what VoiceOver
/// says is testable without standing up a reader.
///
/// **Page numbers are always 1-based and always carry the total.** The right-to-left mode
/// reverses the *pager's* order (a reversed sequence, never a mirror transform), so the
/// only thing that keeps a swipe comprehensible is hearing which page of how many you
/// landed on.
enum ReaderAccessibility {

    /// A single page, paged or vertical. `index` is 0-based, as the view holds it.
    static func pageLabel(index: Int, pageCount: Int) -> String {
        guard pageCount > 0 else { return "Page \(index + 1)" }
        return "Page \(index + 1) of \(pageCount)"
    }

    /// The floating indicator. Says the same sentence as the page it describes rather than
    /// the typography it renders.
    static func pageIndicatorLabel(currentPage: Int, pageCount: Int) -> String {
        let clamped = min(max(currentPage + 1, 1), max(pageCount, 1))
        return "Page \(clamped) of \(pageCount)"
    }

    /// The end-of-chapter mark. "END · 20 PAGES" spoken as a sentence.
    static func endMarkLabel(pageCount: Int) -> String {
        "End of chapter. \(pageCount) \(pageCount == 1 ? "page" : "pages")"
    }

    /// The interstitial the pager shows either side of a chapter boundary — and, when it
    /// is a load trigger, the only thing on screen during the fetch.
    static func interstitialLabel(chapter: Chapter, isNext: Bool, isLoading: Bool) -> String {
        var parts = [isNext ? "Next chapter" : "Previous chapter", "Chapter \(chapter.number)"]
        if let title = chapter.title, !title.isEmpty { parts.append(title) }
        if isLoading { parts.append("Fetching pages") }
        return parts.joined(separator: ", ")
    }
}
