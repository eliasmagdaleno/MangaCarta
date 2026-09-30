import Foundation
import Testing
@testable import MangaCarta

// MARK: - Test doubles

/// Stands in for `ASWebAuthenticationSession`. Records how many presentations happened, so a
/// test can prove a second sign-in tap did not open a second web sheet.
private actor FakeAuthPresenter: MALAuthPresenting {
    enum Outcome {
        case redirect(String)
        case userCancelled
        case failed
        case hang
    }

    private var outcomes: [Outcome]
    private(set) var presentations: [URL] = []

    init(outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    var presentationCount: Int { presentations.count }

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        presentations.append(url)
        guard !outcomes.isEmpty else { throw MALAuthPresentationError.failed }
        switch outcomes.removeFirst() {
        case let .redirect(template):
            // The state is echoed back, exactly as a real callback would.
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "state" }?.value ?? ""
            return URL(string: template.replacingOccurrences(of: "{state}", with: state))!
        case .userCancelled:
            throw MALAuthPresentationError.cancelled
        case .failed:
            throw MALAuthPresentationError.failed
        case .hang:
            try await Task.sleep(nanoseconds: 10_000_000_000)
            throw MALAuthPresentationError.failed
        }
    }
}

private actor ScriptedTokenExchangeTransport: MALHTTPTransport {
    private var steps: [(status: Int, body: String)]
    private(set) var callCount = 0

    init(steps: [(status: Int, body: String)]) {
        self.steps = steps
    }

    var calls: Int { callCount }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        callCount += 1
        guard !steps.isEmpty else { throw URLError(.badServerResponse) }
        let step = steps.removeFirst()
        let response = HTTPURLResponse(url: request.url!,
                                       statusCode: step.status,
                                       httpVersion: nil,
                                       headerFields: nil)!
        return (Data(step.body.utf8), response)
    }
}

private final class InMemoryAccountPreferences: MALAccountPreferenceStore, @unchecked Sendable {
    private(set) var record: MALAccountPreferences?
    /// Survives sign-out: it names whose queued updates are still on disk.
    private(set) var queuedAccountUserID: Int?

    init(record: MALAccountPreferences? = nil, queuedAccountUserID: Int? = nil) {
        self.record = record
        self.queuedAccountUserID = queuedAccountUserID
    }

    func load() -> MALAccountPreferences? { record }
    func save(_ preferences: MALAccountPreferences) { record = preferences }
    func clear() { record = nil }
    func loadQueuedAccountUserID() -> Int? { queuedAccountUserID }
    func saveQueuedAccountUserID(_ userID: Int?) { queuedAccountUserID = userID }
}

// MARK: - Fixtures

private let accountConfiguration = MALOAuthConfiguration(
    clientID: "test-client",
    redirectURI: "mangareader://oauth/mal"
)

private let accountNow = Date(timeIntervalSince1970: 1_000_000)

private let exchangeBody = """
{"token_type":"Bearer","expires_in":3600,"access_token":"a0","refresh_token":"r0"}
"""

private let elias = MALUserIdentity(id: 42, name: "elias", pictureURL: nil)

@MainActor
private final class AccountFixture {
    let store: MALAccountStore
    let presenter: FakeAuthPresenter
    let tokenTransport: ScriptedTokenExchangeTransport
    let credentials: MALCredentialStore
    let preferences: InMemoryAccountPreferences
    let outbox: MALProgressOutbox
    let directory: URL

    init(
        presenterOutcomes: [FakeAuthPresenter.Outcome] = [.redirect("mangareader://oauth/mal?code=c1&state={state}")],
        tokenSteps: [(status: Int, body: String)] = [(200, exchangeBody)],
        identity: @escaping @Sendable (String) async throws -> MALUserIdentity = { _ in elias },
        preferences: InMemoryAccountPreferences = InMemoryAccountPreferences(),
        storedCredential: MALStoredCredential? = nil,
        retryDelivery: @escaping () -> Void = {}
    ) {
        directory = TestDirectory("MALAccountStoreTests").url
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        presenter = FakeAuthPresenter(outcomes: presenterOutcomes)
        tokenTransport = ScriptedTokenExchangeTransport(steps: tokenSteps)
        credentials = MALCredentialStore(
            dataStore: MALInMemoryCredentialDataStore(),
            markerStore: MALInMemoryInstallationMarkerStore(marker: "installation-1")
        ) { "installation-1" }
        if let storedCredential { try? credentials.save(storedCredential) }
        self.preferences = preferences
        outbox = MALProgressOutbox(directory: directory)

        store = MALAccountStore(
            configuration: accountConfiguration,
            presenter: presenter,
            tokenClient: MALTokenClient(configuration: accountConfiguration,
                                        transport: tokenTransport,
                                        now: { accountNow }),
            credentials: credentials,
            preferences: self.preferences,
            outbox: outbox,
            fetchIdentity: identity,
            retryDelivery: retryDelivery,
            now: { accountNow }
        )
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

// MARK: - Sign-in

@MainActor
@Suite("MAL account sign-in")
struct MALAccountStoreSignInTests {
    @Test("A completed sign-in ends signed in with sync and automatic addition on")
    func successfulSignIn() async throws {
        let fixture = AccountFixture()

        await fixture.store.signIn()

        #expect(fixture.store.state == .signedIn(profile: elias,
                                                 syncEnabled: true,
                                                 automaticallyAddsTitles: true))
        let saved = try #require(try fixture.credentials.load())
        #expect(saved.malUserID == 42)
        #expect(saved.accessToken == "a0")
        #expect(fixture.preferences.record?.profile == elias)
    }

    @Test("Cancelling the web sheet returns to signed out without persisting anything")
    func userCancellation() async throws {
        let fixture = AccountFixture(presenterOutcomes: [.userCancelled])

        await fixture.store.signIn()

        #expect(fixture.store.state == .signedOut)
        #expect(try fixture.credentials.load() == nil)
        #expect(await fixture.tokenTransport.calls == 0)
    }

    @Test("A callback that fails validation is a recoverable error over signed out")
    func rejectedCallback() async throws {
        let fixture = AccountFixture(
            presenterOutcomes: [.redirect("mangareader://oauth/mal?code=c1&state=wrong")]
        )

        await fixture.store.signIn()

        #expect(fixture.store.isRecoverableError)
        #expect(fixture.store.stableState == .signedOut)
        #expect(try fixture.credentials.load() == nil)
        #expect(await fixture.tokenTransport.calls == 0)
    }

    @Test("A refused token exchange leaves nothing persisted")
    func tokenExchangeFailure() async throws {
        let fixture = AccountFixture(tokenSteps: [(400, #"{"error":"invalid_grant"}"#)])

        await fixture.store.signIn()

        #expect(fixture.store.isRecoverableError)
        #expect(fixture.store.stableState == .signedOut)
        #expect(try fixture.credentials.load() == nil)
    }

    @Test("An identity fetch failure does not persist a half-known account")
    func identityFailure() async throws {
        let fixture = AccountFixture(identity: { _ in throw MALRequestFailure.transient(retryAfter: nil) })

        await fixture.store.signIn()

        #expect(fixture.store.isRecoverableError)
        #expect(try fixture.credentials.load() == nil)
        #expect(fixture.preferences.record == nil)
    }

    @Test("A second sign-in tap while authorizing does not open a second web sheet")
    func repeatedSignInTaps() async throws {
        let fixture = AccountFixture(presenterOutcomes: [
            .redirect("mangareader://oauth/mal?code=c1&state={state}"),
            .redirect("mangareader://oauth/mal?code=c2&state={state}")
        ])

        async let first: Void = fixture.store.signIn()
        async let second: Void = fixture.store.signIn()
        _ = await (first, second)

        #expect(await fixture.presenter.presentationCount == 1)
        #expect(await fixture.tokenTransport.calls == 1)
    }

    @Test("Cancelling the sign-in task returns to signed out")
    func taskCancellation() async throws {
        let fixture = AccountFixture(presenterOutcomes: [.hang])

        let task = Task { await fixture.store.signIn() }
        try await Task.sleep(nanoseconds: 30_000_000)
        task.cancel()
        await task.value

        #expect(fixture.store.state == .signedOut)
        #expect(try fixture.credentials.load() == nil)
    }
}

// MARK: - Signed-in lifecycle

@MainActor
@Suite("MAL account lifecycle")
struct MALAccountStoreLifecycleTests {
    @Test("Restoring a stored account comes back signed in with its saved preferences")
    func restoreSignedIn() async throws {
        let preferences = InMemoryAccountPreferences(
            record: MALAccountPreferences(profile: elias,
                                          syncEnabled: false,
                                          automaticallyAddsTitles: true)
        )
        let fixture = AccountFixture(
            preferences: preferences,
            storedCredential: MALStoredCredential(tokenType: "Bearer",
                                                  accessToken: "a0",
                                                  refreshToken: "r0",
                                                  expiresAt: accountNow.addingTimeInterval(3600),
                                                  malUserID: 42)
        )

        fixture.store.restore()

        #expect(fixture.store.state == .signedIn(profile: elias,
                                                 syncEnabled: false,
                                                 automaticallyAddsTitles: true))
    }

    @Test("A cached profile with no credential needs reauthorization, not a silent sign-out")
    func restoreWithoutCredential() async throws {
        let preferences = InMemoryAccountPreferences(
            record: MALAccountPreferences(profile: elias,
                                          syncEnabled: true,
                                          automaticallyAddsTitles: true)
        )
        let fixture = AccountFixture(preferences: preferences)

        fixture.store.restore()

        #expect(fixture.store.state == .reauthorizationRequired(profile: elias))
    }

    @Test("Turning sync off keeps the account signed in and the queue intact")
    func disablingSyncDoesNotSignOut() async throws {
        let fixture = AccountFixture()
        await fixture.store.signIn()
        try fixture.outbox.enqueue(userID: 42, mangaID: 7, desiredProgress: 3, completedAt: accountNow)

        fixture.store.setSyncEnabled(false)

        #expect(fixture.store.state == .signedIn(profile: elias,
                                                 syncEnabled: false,
                                                 automaticallyAddsTitles: true))
        #expect(fixture.preferences.record?.syncEnabled == false)
        #expect(fixture.outbox.summary(userID: 42).pending == 1)
    }

    @Test("Signing out deletes the credential, the cached profile, and that account's queue")
    func signOutClearsAccountData() async throws {
        let fixture = AccountFixture()
        await fixture.store.signIn()
        try fixture.outbox.enqueue(userID: 42, mangaID: 7, desiredProgress: 3, completedAt: accountNow)

        try fixture.store.signOut()

        #expect(fixture.store.state == .signedOut)
        #expect(try fixture.credentials.load() == nil)
        #expect(fixture.preferences.record == nil)
        #expect(fixture.outbox.summary(userID: 42).pending == 0)
    }
}

// MARK: - Reauthorization and account switching

@MainActor
@Suite("MAL account reauthorization")
struct MALAccountStoreReauthorizationTests {
    @Test("Reauthorizing the same account keeps the queued work it had")
    func sameAccountResumesRetainedWork() async throws {
        // Two sign-ins: the original, then the one after reauthorization is demanded.
        let fixture = AccountFixture(
            presenterOutcomes: Array(repeating: .redirect("mangareader://oauth/mal?code=c1&state={state}"),
                                     count: 2),
            tokenSteps: Array(repeating: (200, exchangeBody), count: 2)
        )
        await fixture.store.signIn()
        try fixture.outbox.enqueue(userID: 42, mangaID: 7, desiredProgress: 3, completedAt: accountNow)
        fixture.store.reauthorizationRequired()
        #expect(fixture.store.state == .reauthorizationRequired(profile: elias))

        await fixture.store.signIn()

        #expect(fixture.store.state == .signedIn(profile: elias,
                                                 syncEnabled: true,
                                                 automaticallyAddsTitles: true))
        #expect(fixture.store.pendingAccountSwitch == nil)
        #expect(fixture.outbox.summary(userID: 42).pending == 1)
    }

    @Test("Signing in as a different user holds the old queue until the deletion is confirmed")
    func differentAccountRequiresConfirmation() async throws {
        let other = MALUserIdentity(id: 99, name: "someone-else", pictureURL: nil)
        let preferences = InMemoryAccountPreferences(queuedAccountUserID: 42)
        let fixture = AccountFixture(identity: { _ in other }, preferences: preferences)
        try fixture.outbox.enqueue(userID: 42, mangaID: 7, desiredProgress: 3, completedAt: accountNow)

        await fixture.store.signIn()

        let request = try #require(fixture.store.pendingAccountSwitch)
        #expect(request.previousUserID == 42)
        #expect(request.pendingCount == 1)
        // Nothing is deleted on the strength of a sign-in alone.
        #expect(fixture.outbox.summary(userID: 42).pending == 1)
        #expect(fixture.store.state == .signedIn(profile: other,
                                                 syncEnabled: true,
                                                 automaticallyAddsTitles: true))
    }

    @Test("Confirming the switch deletes the previous account's queue")
    func confirmedAccountSwitchClearsOldQueue() async throws {
        let other = MALUserIdentity(id: 99, name: "someone-else", pictureURL: nil)
        let preferences = InMemoryAccountPreferences(queuedAccountUserID: 42)
        let fixture = AccountFixture(identity: { _ in other }, preferences: preferences)
        try fixture.outbox.enqueue(userID: 42, mangaID: 7, desiredProgress: 3, completedAt: accountNow)
        await fixture.store.signIn()

        try fixture.store.confirmAccountSwitchDeletion()

        #expect(fixture.outbox.summary(userID: 42).pending == 0)
        #expect(fixture.store.pendingAccountSwitch == nil)
        #expect(fixture.preferences.queuedAccountUserID == 99)
    }

    @Test("Declining the switch keeps the previous account's queue and stops asking on sign-in")
    func dismissedAccountSwitchKeepsOldQueue() async throws {
        let other = MALUserIdentity(id: 99, name: "someone-else", pictureURL: nil)
        let preferences = InMemoryAccountPreferences(queuedAccountUserID: 42)
        let fixture = AccountFixture(identity: { _ in other }, preferences: preferences)
        try fixture.outbox.enqueue(userID: 42, mangaID: 7, desiredProgress: 3, completedAt: accountNow)
        await fixture.store.signIn()

        fixture.store.dismissAccountSwitch()

        #expect(fixture.outbox.summary(userID: 42).pending == 1)
        #expect(fixture.store.pendingAccountSwitch == nil)
    }
}

// MARK: - Sync summary

@MainActor
@Suite("MAL sync summary")
struct MALAccountSyncSummaryTests {
    private func signedIn(retryDelivery: @escaping () -> Void = {}) -> AccountFixture {
        let preferences = InMemoryAccountPreferences()
        preferences.save(MALAccountPreferences(profile: elias,
                                               syncEnabled: true,
                                               automaticallyAddsTitles: true))
        let fixture = AccountFixture(
            preferences: preferences,
            storedCredential: MALStoredCredential(tokenType: "Bearer",
                                                  accessToken: "access",
                                                  refreshToken: "refresh",
                                                  expiresAt: accountNow.addingTimeInterval(3_600),
                                                  malUserID: elias.id),
            retryDelivery: retryDelivery)
        fixture.store.restore()
        return fixture
    }

    @Test("The summary counts this account's queue and nobody else's")
    func countsOwnQueue() throws {
        let fixture = signedIn()
        let when = accountNow
        try fixture.outbox.enqueue(userID: elias.id, mangaID: 1, desiredProgress: 3,
                                   completedAt: when)
        try fixture.outbox.enqueue(userID: elias.id, mangaID: 2, desiredProgress: 3,
                                   completedAt: when)
        try fixture.outbox.defer(userID: elias.id, workID: WorkID(), desiredProgress: 3,
                                 completedAt: when)
        try fixture.outbox.enqueue(userID: 999, mangaID: 3, desiredProgress: 3, completedAt: when)
        let blocked = try #require(fixture.outbox.nextEligible(userID: elias.id, at: when))
        try fixture.outbox.reschedule(blocked, failure: .permanent, nextAttemptAt: .distantFuture)

        fixture.store.refreshSyncSummary()

        #expect(fixture.store.syncSummary == MALSyncSummary(pending: 1, failed: 1,
                                                            waiting: 1, skipped: 0))
    }

    @Test("Titles the drain skipped are reported alongside the queue")
    func skippedTitles() {
        let fixture = signedIn()

        fixture.store.syncActivityChanged(skipped: 4)

        #expect(fixture.store.syncSummary.skipped == 4)
    }

    /// Retry now must reach the drain. The account store cannot drain anything itself —
    /// it does not own the coordinator — so this is the seam, and this test is what says
    /// the button is wired to something rather than to nothing.
    @Test("Retry now asks the drain to run")
    func retryNowRunsTheDrain() {
        var retries = 0
        let fixture = signedIn(retryDelivery: { retries += 1 })

        fixture.store.retryNow()

        #expect(retries == 1)
    }
}

// MARK: - Token refresh, as the account shows it

@MainActor
@Suite("MAL account refresh state")
struct MALAccountRefreshStateTests {
    private func signedIn() -> AccountFixture {
        let preferences = InMemoryAccountPreferences()
        preferences.save(MALAccountPreferences(profile: elias,
                                               syncEnabled: false,
                                               automaticallyAddsTitles: true))
        let fixture = AccountFixture(
            preferences: preferences,
            storedCredential: MALStoredCredential(tokenType: "Bearer",
                                                  accessToken: "access",
                                                  refreshToken: "refresh",
                                                  expiresAt: accountNow.addingTimeInterval(3_600),
                                                  malUserID: elias.id))
        fixture.store.restore()
        return fixture
    }

    @Test("A refresh in flight shows as refreshing, and ends back on the saved preferences")
    func refreshShowsAndClears() throws {
        let fixture = signedIn()

        fixture.store.refreshBegan()
        #expect(fixture.store.state == .refreshing(profile: elias))

        fixture.store.refreshEnded()
        // Restated from what is saved, not from a remembered copy — the toggles here are
        // deliberately not the defaults, so a hardcoded restatement fails this.
        #expect(fixture.store.state == .signedIn(profile: elias,
                                                 syncEnabled: false,
                                                 automaticallyAddsTitles: true))
    }

    @Test("A refresh for a signed-out account changes nothing")
    func refreshWhileSignedOutIsIgnored() throws {
        let fixture = AccountFixture()

        fixture.store.refreshBegan()

        #expect(fixture.store.state == .signedOut)
    }

    @Test("A refresh that ended in reauthorization does not get restated as signed in")
    func refreshEndDoesNotOverwriteReauthorization() throws {
        let fixture = signedIn()
        fixture.store.refreshBegan()

        // The permanent-failure path: the client marks the account before the token
        // manager's end notification lands. Whichever order they arrive in, the account
        // must not claim to be signed in.
        fixture.store.reauthorizationRequired()
        fixture.store.refreshEnded()

        #expect(fixture.store.state == .reauthorizationRequired(profile: elias))
    }
}
