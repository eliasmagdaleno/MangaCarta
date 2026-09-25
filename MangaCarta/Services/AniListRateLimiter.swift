//
//  AniListRateLimiter.swift
//  MangaCarta
//
//  ADR-0007: AniList is the app's first rate-limited resource, and the budget is
//  *global* — 30 requests/minute, measured live (`x-ratelimit-limit: 30`, not the
//  90 the docs advertise). Home's rail backfill, a detail-page open, and a library
//  refresh all draw on the same allowance, so one object owns it and every request
//  passes through here.
//
//  This is the mechanism only. The *policy* built on top of it — batch of 5,
//  ordered by engagement weight, snapshot TTL by publication status — belongs to
//  the upgrade queue, which lands with the Work store.
//

import Foundation

/// Spaces AniList requests apart, including when callers arrive concurrently.
///
/// The mechanism is **slot reservation**, not "wait since the last one finished".
/// Actors are *reentrant*: suspending at an `await` lets another caller in, so a
/// limiter that slept and only then recorded a timestamp would let a burst of
/// concurrent callers sail straight through — verified, it fired 4 requests in
/// 0.7ms. Each caller instead claims its slot in one uninterrupted step, before any
/// suspension point, so N concurrent callers stagger deterministically.
actor AniListRateLimiter {
    /// 2s ⇒ 30/min exactly, the measured ceiling. Spacing rather than a token
    /// bucket: a burst of 30 followed by a 60s stall would technically respect the
    /// limit while making the app appear frozen, and nothing here is urgent enough
    /// to want the burst.
    static let defaultInterval: TimeInterval = 2.0

    private let limiter: RateLimiter

    init(minimumInterval: TimeInterval = AniListRateLimiter.defaultInterval,
         clock: any RateLimiterClock = SystemRateLimiterClock(),
         sleeper: any RateLimiterSleeper = TaskRateLimiterSleeper()) {
        limiter = RateLimiter(minimumInterval: minimumInterval, clock: clock, sleeper: sleeper)
    }

    /// Runs `operation` no earlier than its reserved slot. A cold limiter runs
    /// immediately — the first request is never delayed, because a user-initiated
    /// fetch must not pay for a budget nobody has spent.
    func run<T>(_ operation: () async throws -> T) async rethrows -> T {
        _ = try? await limiter.acquire(ignoringCancellation: true)
        return try await operation()
    }
}
