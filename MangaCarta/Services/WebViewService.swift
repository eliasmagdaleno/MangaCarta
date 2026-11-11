//
//  WebViewService.swift
//  MangaCarta
//
//  The Cloudflare-clearing HTML-extraction engine behind WebView-based sources
//  (WeebCentral now; more sources in later phases). Loads a page in a shared
//  off-screen WKWebView — a real browser, so Cloudflare's non-interactive JS
//  challenge clears itself — then runs an injected JS script whose final expression
//  is a JSON string, and decodes it into a Codable DTO. When Cloudflare demands an
//  interactive (Turnstile) tap, `isChallengeActive` flips and ContentView presents
//  the WebView in a sheet; once the target page loads challenge-free, extraction
//  resumes automatically.
//

import Foundation
import WebKit
import Combine

@MainActor
final class WebViewService: NSObject, ObservableObject, WebViewExtracting {
    static let shared = WebViewService()

    /// True while an interactive Cloudflare challenge needs the user. Drives the
    /// sheet in ContentView; the service flips it back off when the challenge clears.
    @Published var isChallengeActive = false

    /// The shared browser. Exposed so CloudflareChallengeView can host it on screen
    /// while a challenge is active; lives off-screen the rest of the time.
    let webView: WKWebView

    private let navigationTimeout: TimeInterval = 30
    private let challengeTimeout: TimeInterval = 120
    private let scriptTimeout: TimeInterval = 15
    private let declineStickiness: TimeInterval = 30
    private let dismissalEchoWindow: TimeInterval = 1.5

    // Single-flight state — only ever touched on the MainActor.
    private var lockBusy = false
    private var lockWaiters: [CheckedContinuation<Void, Never>] = []
    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var challengeContinuation: CheckedContinuation<Void, Error>?
    private var scriptContinuation: CheckedContinuation<String, Error>?
    /// Identity of the current `runScript` run. An `evaluateJavaScript` callback that
    /// straggles in after its run timed out must not resume a LATER extract's script
    /// wait with the wrong script's output — same staleness class as `currentNavigation`.
    private var scriptGeneration = 0
    private var sawChallengeHeader = false
    /// Sticky decline: while set and in the future, extracts that hit a Cloudflare
    /// challenge fail fast with `.cloudflareUnsolved` instead of re-presenting the
    /// sheet. Armed whenever a challenge wait ends unsolved (user decline OR the
    /// 120 s timeout) so queued extracts can't cascade sheets at the user; cleared
    /// the moment a challenge is actually solved. Pages that load challenge-free
    /// are unaffected by the window.
    private var challengeDeclinedUntil: Date?
    /// When the *service* ends a challenge while its sheet is still presented
    /// (solve, timeout, or the sheet's Cancel button), the programmatic dismissal
    /// echoes one `cancelChallenge()` through the sheet's onDismiss. Calls arriving
    /// within this deadline are that echo and are swallowed, so a stale dismissal
    /// callback can never decline a LATER extract's challenge. A user swipe writes
    /// `isChallengeActive = false` *before* onDismiss runs, so no echo window is
    /// armed on that path and genuine declines are never swallowed.
    private var dismissalEchoDeadline: Date?
    /// The navigation the pending `load(_:)` is waiting on. Client-side redirects
    /// supersede it (adopted in `didStartProvisionalNavigation`); callbacks for any
    /// other navigation — e.g. stragglers from a timed-out earlier load — are ignored.
    private var currentNavigation: WKNavigation?

    override init() {
        let config = WKWebViewConfiguration()
        // Persistent store: cf_clearance must survive across loads AND app relaunches.
        config.websiteDataStore = .default()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        // cf_clearance is bound to the UA that earned it — pin one real UA for every load.
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
        super.init()
        webView.navigationDelegate = self
    }

    // MARK: - WebViewExtracting

    // Nonisolated so the non-Sendable `T.Type`/`T` never cross an actor boundary
    // (the protocol's callers aren't MainActor); only the Sendable script output
    // string comes back from the MainActor browser work below.
    nonisolated func extract<T: Decodable>(from url: URL, script: String, as type: T.Type) async throws -> T {
        let json = try await extractJSON(from: url, script: script)
        do {
            return try JSONDecoder().decode(T.self, from: Data(json.utf8))
        } catch {
            throw SourceError.extractionFailed("decoding script output: \(error.localizedDescription)")
        }
    }

    /// The serialized load → (challenge wait) → script-run pipeline, on the MainActor.
    private func extractJSON(from url: URL, script: String) async throws -> String {
        try await withLock {
            // A fetch cancelled while queued for the lock must not drive the browser
            // (or worse, summon the challenge sheet) for a result nobody wants.
            try Task.checkCancellation()
            try await self.load(url)
            if self.sawChallengeHeader {
                // Re-check: cancellation during the page load must not flip
                // isChallengeActive for a dead fetch.
                try Task.checkCancellation()
                // Sticky decline: the user (or the 120 s timeout) just refused a
                // challenge — don't re-present the sheet for every queued extract;
                // fail fast until the window lapses or a challenge gets solved.
                if let until = self.challengeDeclinedUntil, Date() < until {
                    throw SourceError.cloudflareUnsolved
                }
                try await self.awaitChallengeResolution()
            }
            return try await self.runScript(script)
        }
    }

    /// Called when the user declines the challenge sheet (swipe-dismiss or its Cancel
    /// button). Safe to call redundantly: the sheet's onDismiss also fires after the
    /// service closes the sheet itself (solve/timeout/Cancel button) — those echoes
    /// land inside `dismissalEchoDeadline` and are ignored, so they can never decline
    /// a challenge that a LATER extract has since started waiting on.
    func cancelChallenge() {
        if let deadline = dismissalEchoDeadline, Date() < deadline { return }
        guard challengeContinuation != nil else { return }
        resumeChallenge(.failure(SourceError.cloudflareUnsolved))
    }

#if DEBUG
    /// UI tests only: the real challenge wait, with no site behind it, so a hermetic test
    /// can put the sheet up from a fixture Source (`MALHubUITests`). Same timeout and Cancel.
    func uiTestAwaitChallenge() async throws {
        try await awaitChallengeResolution()
    }
#endif

    // MARK: - Navigation plumbing

    private func load(_ url: URL) async throws {
        sawChallengeHeader = false
        let deadline = Task { [navigationTimeout] in
            try? await Task.sleep(for: .seconds(navigationTimeout))
            // A cancelled deadline still reaches this line (the `try?` swallows
            // CancellationError) — bail so it can't fail a *later* load's continuation.
            guard !Task.isCancelled else { return }
            self.webView.stopLoading()
            self.resumeLoad(.failure(SourceError.navigationFailed("timed out loading \(url.absoluteString)")))
        }
        defer { deadline.cancel() }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            loadContinuation = cont
            currentNavigation = webView.load(URLRequest(url: url))
        }
    }

    private func awaitChallengeResolution() async throws {
        isChallengeActive = true
        defer { isChallengeActive = false }
        let deadline = Task { [challengeTimeout] in
            try? await Task.sleep(for: .seconds(challengeTimeout))
            guard !Task.isCancelled else { return }  // same straggler guard as load()
            self.resumeChallenge(.failure(SourceError.cloudflareUnsolved))
        }
        defer { deadline.cancel() }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            challengeContinuation = cont
        }
    }

    private func runScript(_ script: String) async throws -> String {
        scriptGeneration += 1
        let generation = scriptGeneration
        let deadline = Task { [scriptTimeout] in
            try? await Task.sleep(for: .seconds(scriptTimeout))
            // Same straggler guard as load(): a cancelled deadline still reaches this
            // line (`try?` swallows CancellationError) — bail so it can't fail a
            // *later* extract's script wait.
            guard !Task.isCancelled else { return }
            self.resumeScript(.failure(SourceError.extractionFailed("script timed out")))
        }
        defer { deadline.cancel() }
        // Completion-handler variant on purpose: the async overload traps if JS returns nil.
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            scriptContinuation = cont
            webView.evaluateJavaScript(script) { result, error in
                // A callback straggling in after this run timed out must not touch a
                // later run's continuation (nil-check alone can't tell them apart).
                guard generation == self.scriptGeneration else { return }
                if let error {
                    self.resumeScript(.failure(SourceError.extractionFailed(error.localizedDescription)))
                } else if let json = result as? String {
                    self.resumeScript(.success(json))
                } else {
                    self.resumeScript(.failure(SourceError.extractionFailed("script did not return a JSON string")))
                }
            }
        }
    }

    // Single-resume guards: delegate callbacks and timeouts can race; whoever gets
    // there first wins, later calls are no-ops.
    private func resumeLoad(_ result: Result<Void, Error>) {
        guard let cont = loadContinuation else { return }
        loadContinuation = nil
        cont.resume(with: result)
    }

    private func resumeScript(_ result: Result<String, Error>) {
        guard let cont = scriptContinuation else { return }
        scriptContinuation = nil
        cont.resume(with: result)
    }

    private func resumeChallenge(_ result: Result<Void, Error>) {
        guard let cont = challengeContinuation else { return }
        challengeContinuation = nil
        // If the sheet is still presented, we're about to close it programmatically
        // (a user swipe already wrote isChallengeActive = false before reaching here);
        // arm the echo window so the dismissal's onDismiss → cancelChallenge is inert.
        if isChallengeActive {
            dismissalEchoDeadline = Date().addingTimeInterval(dismissalEchoWindow)
        }
        // Solved → clear any sticky decline; unsolved (decline or timeout) → arm it.
        switch result {
        case .success: challengeDeclinedUntil = nil
        case .failure: challengeDeclinedUntil = Date().addingTimeInterval(declineStickiness)
        }
        cont.resume(with: result)
    }

    /// True when a delegate callback belongs to the navigation `load(_:)` is waiting on.
    /// WKWebView occasionally hands delegates a nil navigation — treat that as matching
    /// (better a rare wrong resume than a guaranteed hang until timeout).
    private func isCurrentNavigation(_ navigation: WKNavigation?) -> Bool {
        guard let navigation, let currentNavigation else { return true }
        return navigation === currentNavigation
    }

    private func handleNavigationFailure(_ navigation: WKNavigation?, _ error: Error) {
        let nsError = error as NSError
        // "Cancelled" means this navigation was superseded — by a client-side redirect,
        // or by our own stopLoading()/next load. Never terminal; the superseding
        // navigation (or the timeout) resolves the wait.
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        guard isCurrentNavigation(navigation) else { return }
        resumeLoad(.failure(SourceError.navigationFailed(error.localizedDescription)))
    }

    /// Serializes extracts: one WKWebView, one in-flight navigation at a time.
    private func withLock<T>(_ body: () async throws -> T) async rethrows -> T {
        while lockBusy {
            await withCheckedContinuation { lockWaiters.append($0) }
        }
        lockBusy = true
        defer {
            lockBusy = false
            if !lockWaiters.isEmpty { lockWaiters.removeFirst().resume() }
        }
        return try await body()
    }
}

// MARK: - WKNavigationDelegate

extension WebViewService: WKNavigationDelegate {
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if navigationResponse.isForMainFrame,
           let http = navigationResponse.response as? HTTPURLResponse {
            sawChallengeHeader = http.value(forHTTPHeaderField: "cf-mitigated")?.lowercased() == "challenge"
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // While a load is pending, any new main-frame navigation is part of its chain
        // (a JS/meta redirect that superseded the one we started) — adopt it so its
        // didFinish/didFail resolve the pending load.
        if loadContinuation != nil, let navigation {
            currentNavigation = navigation
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if loadContinuation != nil {
            guard isCurrentNavigation(navigation) else { return }
            // Initial load finished — possibly on the challenge page; extract() checks
            // sawChallengeHeader next and waits for resolution if needed.
            resumeLoad(.success(()))
        } else if challengeContinuation != nil, !sawChallengeHeader {
            // A main-frame load completed without the challenge header while we were
            // waiting: the challenge cleared and Cloudflare reloaded the target page.
            // (Challenge-page self-reloads still carry the header and are ignored.)
            resumeChallenge(.success(()))
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleNavigationFailure(navigation, error)
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleNavigationFailure(navigation, error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // iOS reaps off-screen web content processes under memory pressure. Whatever
        // was in flight is dead — fail every pending wait so no extract hangs on a
        // continuation nothing will ever resume. WKWebView recreates the process on
        // its next load, so the following extract starts clean.
        let reason = SourceError.navigationFailed("web content process terminated")
        resumeLoad(.failure(reason))
        // If the sheet was up, this arms the dismissal-echo window (we're closing the
        // sheet programmatically), keeping the onDismiss echo inert — desired.
        resumeChallenge(.failure(reason))
        resumeScript(.failure(reason))
        // Termination is NOT a user decline: undo the sticky-decline window that
        // resumeChallenge's failure branch just armed (and any earlier one — the
        // browser state it was protecting is gone). The next extract may present
        // a fresh challenge in the recreated process.
        challengeDeclinedUntil = nil
        // awaitChallengeResolution's defer clears this as its continuation resumes;
        // clear it here too so nothing dangles even if no challenge wait was pending.
        isChallengeActive = false
    }
}
