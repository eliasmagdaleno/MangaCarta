//
//  MALTokenManager.swift
//  MangaCarta
//
//  Owns the live MAL credential: reads it from the Keychain once, hands out an access token,
//  and refreshes proactively before expiry. Actor-isolated so the refresh is single-flight —
//  a burst of progress pushes must produce one token request, not one per push.
//

import Foundation

actor MALTokenManager {
    private let client: MALTokenClient
    private let store: MALCredentialStore
    private let now: @Sendable () -> Date
    /// Told `true` when a refresh starts and `false` when it ends. This is what makes
    /// `MALAccountStore.State.refreshing` reachable — without it the state has a
    /// presentation and no producer. Called at the single-flight boundary, so a burst of
    /// pushes that shares one token request also shares one notification.
    private let refreshDidChange: @Sendable (Bool) -> Void

    /// `false` until the Keychain has been read once; `credential` is meaningless before then.
    private var hasLoaded = false
    private var credential: MALStoredCredential?
    /// The one refresh in flight, if any. Late callers await this rather than starting another.
    private var refreshTask: Task<MALStoredCredential, any Error>?
    private var generation = 0

    init(
        client: MALTokenClient,
        store: MALCredentialStore,
        now: @escaping @Sendable () -> Date = { Date() },
        refreshDidChange: @escaping @Sendable (Bool) -> Void = { _ in }
    ) {
        self.client = client
        self.store = store
        self.now = now
        self.refreshDidChange = refreshDidChange
    }

    func invalidate() {
        let wasRefreshing = refreshTask != nil
        refreshTask?.cancel()
        refreshTask = nil
        credential = nil
        hasLoaded = false
        generation += 1
        if wasRefreshing { refreshDidChange(false) }
    }

    /// A usable access token, refreshing first if the stored one is at or near expiry.
    func accessToken() async throws -> String {
        guard let current = try current() else { throw MALTokenError.signedOut }
        guard current.needsRefresh(at: now()) else { return current.accessToken }
        return try await refresh(from: current).accessToken
    }

    /// A token guaranteed to be newer than `staleToken`, for a caller whose request came back
    /// 401 with it. If another caller already refreshed in the meantime the current token is
    /// returned untouched; otherwise this joins the same single-flight refresh, so a burst of
    /// 401s costs one token request.
    func accessToken(replacing staleToken: String) async throws -> String {
        guard let current = try current() else { throw MALTokenError.signedOut }
        guard current.accessToken == staleToken else { return current.accessToken }
        return try await refresh(from: current).accessToken
    }

    /// Forgets the account locally. The MAL-side token is not revoked; MAL exposes no
    /// revocation endpoint.
    func signOut() throws {
        try store.delete()
        credential = nil
        hasLoaded = true
    }

    private func current() throws -> MALStoredCredential? {
        if !hasLoaded {
            credential = try store.load()
            hasLoaded = true
        }
        return credential
    }

    private func refresh(from current: MALStoredCredential) async throws -> MALStoredCredential {
        if let refreshTask { return try await refreshTask.value }

        let refreshGeneration = generation

        // Announced by the caller that *owns* the refresh — the joiners above returned
        // already — and ended in the `defer`, so a refresh that throws still clears.
        refreshDidChange(true)
        let task = Task<MALStoredCredential, any Error> { [self] in
            try await performRefresh(from: current, generation: refreshGeneration)
        }
        refreshTask = task
        defer {
            if generation == refreshGeneration {
                refreshTask = nil
                refreshDidChange(false)
            }
        }
        return try await task.value
    }

    private func performRefresh(
        from current: MALStoredCredential,
        generation refreshGeneration: Int
    ) async throws -> MALStoredCredential {
        do {
            let fresh = try await client.fetch(.refresh(refreshToken: current.refreshToken))
            let updated = MALStoredCredential(tokenType: fresh.tokenType,
                                              accessToken: fresh.accessToken,
                                              refreshToken: fresh.refreshToken,
                                              expiresAt: fresh.expiresAt,
                                              malUserID: current.malUserID)
            guard generation == refreshGeneration else { throw CancellationError() }
            // Persist before publishing: a token handed out but not saved would be lost on
            // the next launch while MAL had already retired its predecessor.
            do {
                try store.save(updated)
            } catch {
                throw MALTokenError.persistenceFailed
            }
            credential = updated
            return updated
        } catch let error as MALTokenError where error.isPermanent {
            // The refresh token will never work again, so the record is dead weight and
            // holding it would only produce the same refusal on every later call.
            try? store.delete()
            credential = nil
            hasLoaded = true
            throw error
        }
    }
}

private extension MALStoredCredential {
    func needsRefresh(at now: Date) -> Bool {
        now.addingTimeInterval(MALCredential.refreshMargin) >= expiresAt
    }
}
