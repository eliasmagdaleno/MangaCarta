//
//  MALAccountStore.swift
//  MangaCarta
//
//  The observable MyAnimeList account: one explicit state, the sign-in flow that moves
//  through it, and the local sign-out that takes the account's data with it.
//
//  Sign-in is optional and nothing here is on the reading path. Tokens live in the Keychain
//  (`MALCredentialStore`); only the non-secret profile cache and the two sync preferences are
//  stored here.
//

import Foundation

/// The non-secret account cache. Safe to keep outside the Keychain: a display name and an
/// avatar URL are presentation data, and the two switches are preferences.
struct MALAccountPreferences: Codable, Equatable, Sendable {
    var profile: MALUserIdentity
    var syncEnabled: Bool
    var automaticallyAddsTitles: Bool
}

protocol MALAccountPreferenceStore: AnyObject, Sendable {
    func load() -> MALAccountPreferences?
    func save(_ preferences: MALAccountPreferences)
    func clear()
    /// Whose queued updates are still on disk. Deliberately outlives `clear()`: a sign-out
    /// must not silently orphan another account's queue.
    func loadQueuedAccountUserID() -> Int?
    func saveQueuedAccountUserID(_ userID: Int?)
}

/// A pending question for the user: signing in as a different MAL account leaves the previous
/// account's queued updates on disk, and they are deleted only if the user says so.
struct MALAccountSwitchRequest: Equatable, Sendable {
    let previousUserID: Int
    let pendingCount: Int
}

@MainActor
final class MALAccountStore: ObservableObject {
    /// The one explicit account state. `error` keeps the stable state it interrupted, so a
    /// dismissed message returns the UI exactly where it was.
    indirect enum State: Equatable {
        case signedOut
        case authorizing
        case signedIn(profile: MALUserIdentity, syncEnabled: Bool, automaticallyAddsTitles: Bool)
        case refreshing(profile: MALUserIdentity)
        case reauthorizationRequired(profile: MALUserIdentity?)
        case error(message: String, previousStable: State)
    }

    @Published private(set) var state: State = .signedOut
    @Published private(set) var pendingAccountSwitch: MALAccountSwitchRequest?
    /// The queue as Settings shows it. Recomputed from the outbox rather than counted
    /// incrementally: the outbox is the durable truth, and a counter that drifts from it
    /// would be worse than no counter at all.
    @Published private(set) var syncSummary: MALSyncSummary = .empty

    private let configuration: MALOAuthConfiguration
    private let presenter: any MALAuthPresenting
    private let tokenClient: MALTokenClient
    private let credentials: MALCredentialStore
    private let preferences: any MALAccountPreferenceStore
    private let outbox: any MALProgressOutboxProtocol
    private let fetchIdentity: @Sendable (String) async throws -> MALUserIdentity
    private let invalidateTokenCache: @Sendable () async -> Void
    /// **Retry now**. The account store owns no drain — the coordinator does — so this is
    /// the seam between the button and the queue.
    private let retryDelivery: () -> Void
    private let now: @Sendable () -> Date
    private let makeVerifier: @Sendable () -> String
    private let makeState: @Sendable () -> String

    /// Non-nil exactly while a sign-in is in flight, so a second tap joins it rather than
    /// opening a second web sheet.
    private var signInTask: Task<Void, Never>?

    init(
        configuration: MALOAuthConfiguration,
        presenter: any MALAuthPresenting,
        tokenClient: MALTokenClient,
        credentials: MALCredentialStore,
        preferences: any MALAccountPreferenceStore,
        outbox: any MALProgressOutboxProtocol,
        fetchIdentity: @escaping @Sendable (String) async throws -> MALUserIdentity,
        invalidateTokenCache: @escaping @Sendable () async -> Void = {},
        retryDelivery: @escaping () -> Void = {},
        now: @escaping @Sendable () -> Date = { Date() },
        makeVerifier: @escaping @Sendable () -> String = {
            MALPKCE.makeVerifier(randomBytes: MALAccountStore.randomBytes)
        },
        makeState: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.configuration = configuration
        self.presenter = presenter
        self.tokenClient = tokenClient
        self.credentials = credentials
        self.preferences = preferences
        self.outbox = outbox
        self.fetchIdentity = fetchIdentity
        self.invalidateTokenCache = invalidateTokenCache
        self.retryDelivery = retryDelivery
        self.now = now
        self.makeVerifier = makeVerifier
        self.makeState = makeState
    }

    // MARK: Lifecycle

    /// Rebuilds the state at launch from what is on disk. A cached profile whose credential
    /// is gone is `reauthorizationRequired`, not a silent sign-out: the user believes they
    /// are signed in, and their queued work is still theirs.
    func restore() {
        guard let cached = preferences.load() else {
            state = .signedOut
            syncSummary = .empty
            return
        }
        let credential = try? credentials.load()
        guard credential != nil else {
            state = .reauthorizationRequired(profile: cached.profile)
            refreshSyncSummary()
            return
        }
        state = .signedIn(profile: cached.profile,
                          syncEnabled: cached.syncEnabled,
                          automaticallyAddsTitles: cached.automaticallyAddsTitles)
        refreshSyncSummary()
    }

    /// The two switches as last saved, for the states that do not restate them.
    var syncToggles: MALSyncToggles {
        guard let record = preferences.load() else { return .defaults }
        return MALSyncToggles(syncEnabled: record.syncEnabled,
                              automaticallyAddsTitles: record.automaticallyAddsTitles)
    }

    /// Recounts the queue for the signed-in account. `skipped` is not in the outbox — a
    /// skipped title is dropped, not stored — so the drain reports it and it is carried
    /// here until the app restarts.
    func refreshSyncSummary(skipped: Int? = nil) {
        if let skipped { skippedCount = skipped }
        guard let userID = currentProfile?.id else {
            syncSummary = .empty
            return
        }
        let counts = outbox.summary(userID: userID)
        syncSummary = MALSyncSummary(pending: counts.pending,
                                     failed: counts.blocked,
                                     waiting: counts.deferred,
                                     skipped: skippedCount)
    }

    /// Called by the drain after an item's outcome, so Settings follows the queue without
    /// polling it.
    func syncActivityChanged(skipped: Int) {
        refreshSyncSummary(skipped: skipped)
    }

    /// **Retry now**: drain again, immediately, including past a pause.
    func retryNow() {
        retryDelivery()
    }

    private var skippedCount = 0

    /// A token refresh started. Only a signed-in account can be refreshing — every other
    /// state either has no token to refresh or is already telling the user something more
    /// important, so this is a no-op there rather than a state that lies.
    func refreshBegan() {
        guard case let .signedIn(profile, _, _) = state else { return }
        state = .refreshing(profile: profile)
    }

    /// The refresh finished, however it finished. Restated from the saved preferences
    /// rather than from a remembered copy, and guarded on `.refreshing` — a refresh that
    /// failed permanently has already moved the account to `reauthorizationRequired`, and
    /// this must not talk it back into looking signed in.
    func refreshEnded() {
        guard case let .refreshing(profile) = state else { return }
        let toggles = syncToggles
        state = .signedIn(profile: profile,
                          syncEnabled: toggles.syncEnabled,
                          automaticallyAddsTitles: toggles.automaticallyAddsTitles)
    }

#if DEBUG
    /// The account-switch question, put on screen without a second real sign-in. The
    /// question itself is produced by `finishSignIn` and unit-tested there; this exists
    /// only so the alert's wording and buttons can be looked at on a device.
    func seedPendingAccountSwitchForUITesting(previousUserID: Int, pendingCount: Int) {
        pendingAccountSwitch = MALAccountSwitchRequest(previousUserID: previousUserID,
                                                       pendingCount: pendingCount)
    }
#endif

    /// Marks the account as needing a fresh sign-in. Called when a request comes back
    /// `reauthorizationRequired`; the queue is retained, and local reading is unaffected.
    func reauthorizationRequired() {
        state = .reauthorizationRequired(profile: currentProfile)
    }

    // MARK: Sign-in

    func signIn() async {
        let task: Task<Void, Never>
        if let signInTask {
            task = signInTask
        } else {
            task = Task { await performSignIn() }
            signInTask = task
        }
        // The sign-in runs in an unstructured task so a second tap can join it. That means
        // cancelling the caller does not cancel it on its own — this hands the cancellation
        // across, or a cancelled sign-in would keep a web sheet alive behind the user.
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if signInTask == task { signInTask = nil }
    }

    private func performSignIn() async {
        let stable = stableState
        state = .authorizing

        let verifier = makeVerifier()
        let session = MALOAuthSession(configuration: configuration,
                                      state: makeState(),
                                      verifier: verifier)

        let callback: URL
        do {
            callback = try await presenter.authenticate(
                url: session.authorizationURL,
                callbackScheme: Self.callbackScheme(from: configuration.redirectURI)
            )
        } catch MALAuthPresentationError.cancelled {
            // Declining is not a failure and gets no error message.
            state = stable
            return
        } catch is CancellationError {
            state = stable
            return
        } catch {
            state = .error(message: Self.signInFailureMessage, previousStable: stable)
            return
        }

        if Task.isCancelled {
            state = stable
            return
        }

        let code: String
        switch session.complete(with: callback) {
        case let .code(value):
            code = value
        case .cancelled:
            state = stable
            return
        case .failed, .rejected:
            state = .error(message: Self.signInFailureMessage, previousStable: stable)
            return
        }

        do {
            let credential = try await tokenClient.fetch(session.exchange(code: code))
            // The identity read comes before anything is persisted: a credential is stored
            // only once it is known whose it is.
            let profile = try await fetchIdentity(credential.accessToken)
            try await adopt(credential: credential, profile: profile)
        } catch is CancellationError {
            state = stable
        } catch {
            state = .error(message: Self.signInFailureMessage, previousStable: stable)
        }
    }

    private func adopt(credential: MALCredential, profile: MALUserIdentity) async throws {
        try credentials.save(MALStoredCredential(tokenType: credential.tokenType,
                                                 accessToken: credential.accessToken,
                                                 refreshToken: credential.refreshToken,
                                                 expiresAt: credential.expiresAt,
                                                 malUserID: profile.id))
        await invalidateTokenCache()

        // Sync and automatic addition default on for a new account, and a reauthorization of
        // the same account keeps whatever the user last chose.
        let existing = preferences.load()
        let carried = existing?.profile.id == profile.id ? existing : nil
        let record = MALAccountPreferences(
            profile: profile,
            syncEnabled: carried?.syncEnabled ?? true,
            automaticallyAddsTitles: carried?.automaticallyAddsTitles ?? true
        )
        preferences.save(record)

        let queuedOwner = preferences.loadQueuedAccountUserID()
        if let queuedOwner, queuedOwner != profile.id {
            // Another account's updates are still queued. They are never sent to this
            // account, and they are deleted only if the user confirms it.
            pendingAccountSwitch = MALAccountSwitchRequest(
                previousUserID: queuedOwner,
                pendingCount: outbox.summary(userID: queuedOwner).pending
            )
        } else {
            pendingAccountSwitch = nil
            preferences.saveQueuedAccountUserID(profile.id)
        }

        state = .signedIn(profile: record.profile,
                          syncEnabled: record.syncEnabled,
                          automaticallyAddsTitles: record.automaticallyAddsTitles)
    }

    // MARK: Account switching

    /// Deletes the previous account's queued updates. Only ever called from an explicit
    /// confirmation.
    func confirmAccountSwitchDeletion() throws {
        guard let request = pendingAccountSwitch else { return }
        try outbox.clear(userID: request.previousUserID)
        pendingAccountSwitch = nil
        if case let .signedIn(profile, _, _) = state {
            preferences.saveQueuedAccountUserID(profile.id)
        }
    }

    /// Leaves the previous account's queue alone. It is not drained — the drain is keyed by
    /// the signed-in user — but it stays recoverable if that account signs in again.
    func dismissAccountSwitch() {
        pendingAccountSwitch = nil
    }

    // MARK: Preferences

    func setSyncEnabled(_ enabled: Bool) {
        update { $0.syncEnabled = enabled }
    }

    func setAutomaticallyAddsTitles(_ enabled: Bool) {
        update { $0.automaticallyAddsTitles = enabled }
    }

    private func update(_ change: (inout MALAccountPreferences) -> Void) {
        guard var record = preferences.load() else { return }
        change(&record)
        preferences.save(record)
        state = .signedIn(profile: record.profile,
                          syncEnabled: record.syncEnabled,
                          automaticallyAddsTitles: record.automaticallyAddsTitles)
    }

    // MARK: Sign-out

    /// Sign out **on this device**: MAL publishes no revocation endpoint, so this deletes
    /// local account data and nothing else. History, Library, and Works are untouched — they
    /// are the user's own reading, not account data.
    func signOut() async throws {
        signInTask?.cancel()
        signInTask = nil
        pendingAccountSwitch = nil

        let userID = (try? credentials.load())??.malUserID
        try credentials.delete()
        await invalidateTokenCache()
        preferences.clear()
        if let userID {
            try outbox.clear(userID: userID)
            preferences.saveQueuedAccountUserID(nil)
        }
        state = .signedOut
    }

    // MARK: Presentation helpers

    /// The state an error interrupted, or the current state when there is no error. This is
    /// what a dismissed message returns to.
    var stableState: State {
        if case let .error(_, previousStable) = state { return previousStable }
        return state
    }

    var isRecoverableError: Bool {
        if case .error = state { return true }
        return false
    }

    var currentProfile: MALUserIdentity? {
        switch stableState {
        case let .signedIn(profile, _, _), let .refreshing(profile):
            return profile
        case let .reauthorizationRequired(profile):
            return profile
        case .signedOut, .authorizing:
            return preferences.load()?.profile
        case .error:
            return nil
        }
    }

    private static let signInFailureMessage =
        "MyAnimeList sign-in could not be completed. Please try again."

    /// `mangareader://oauth/mal` presents to `ASWebAuthenticationSession` as the scheme alone.
    private static func callbackScheme(from redirectURI: String) -> String {
        URLComponents(string: redirectURI)?.scheme ?? redirectURI
    }

    private static let randomBytes: @Sendable (Int) -> Data = { count in
        Data((0..<count).map { _ in UInt8.random(in: UInt8.min...UInt8.max) })
    }
}

/// Production preference storage. `UserDefaults` is right here: none of it is secret, and the
/// queued-account marker must survive a sign-out.
final class MALUserDefaultsAccountPreferenceStore: MALAccountPreferenceStore, @unchecked Sendable {
    private enum Key {
        static let account = "mal.account.preferences"
        static let queuedAccount = "mal.account.queuedUserID"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> MALAccountPreferences? {
        guard let data = defaults.data(forKey: Key.account) else { return nil }
        return try? JSONDecoder().decode(MALAccountPreferences.self, from: data)
    }

    func save(_ preferences: MALAccountPreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: Key.account)
    }

    func clear() {
        defaults.removeObject(forKey: Key.account)
    }

    func loadQueuedAccountUserID() -> Int? {
        defaults.object(forKey: Key.queuedAccount) as? Int
    }

    func saveQueuedAccountUserID(_ userID: Int?) {
        if let userID {
            defaults.set(userID, forKey: Key.queuedAccount)
        } else {
            defaults.removeObject(forKey: Key.queuedAccount)
        }
    }
}

/// A signed-out MAL account that leaves no trace, for UI tests.
///
/// `MALInMemoryCredentialDataStore` alone is not enough to reach `.signedOut`: `restore()`
/// reads preferences *first*, and a cached profile with no credential is
/// `.reauthorizationRequired`. Isolating the account therefore takes both halves.
final class MALInMemoryAccountPreferenceStore: MALAccountPreferenceStore, @unchecked Sendable {
    private let lock = NSLock()
    private var preferences: MALAccountPreferences?
    private var queuedAccountUserID: Int?

    init() {}

    func load() -> MALAccountPreferences? {
        lock.withLock { preferences }
    }

    func save(_ preferences: MALAccountPreferences) {
        lock.withLock { self.preferences = preferences }
    }

    func clear() {
        lock.withLock { preferences = nil }
    }

    func loadQueuedAccountUserID() -> Int? {
        lock.withLock { queuedAccountUserID }
    }

    func saveQueuedAccountUserID(_ userID: Int?) {
        lock.withLock { queuedAccountUserID = userID }
    }
}
