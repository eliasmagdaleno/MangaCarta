import Foundation

struct HostRateLimitRule: Sendable, Equatable {
    let origin: String
    let pathPrefix: String
    let interval: TimeInterval

    init(origin: String, pathPrefix: String, requestsPerMinute: Double) {
        self.origin = origin
        self.pathPrefix = pathPrefix
        self.interval = 60 / requestsPerMinute
    }
}

/// Owns one origin limiter and zero or more path limiters for each Source.
actor HostRateLimiterRegistry {
    private struct LimiterKey: Hashable, Sendable {
        let sourceID: QualifiedSourceID
        let origin: String
        let pathPrefix: String?
    }
    static let defaultInterval: TimeInterval = 0.2
    static let defaultRules = [HostRateLimitRule(origin: "https://api.mangadex.org",
                                                  pathPrefix: "/at-home/server",
                                                  requestsPerMinute: 40)]

    private let defaultInterval: TimeInterval
    private let rules: [HostRateLimitRule]
    private let clock: any RateLimiterClock
    private let sleeper: any RateLimiterSleeper
    private var limiters: [LimiterKey: RateLimiter] = [:]

    init(defaultInterval: TimeInterval = HostRateLimiterRegistry.defaultInterval,
         rules: [HostRateLimitRule] = HostRateLimiterRegistry.defaultRules,
         clock: any RateLimiterClock = SystemRateLimiterClock(),
         sleeper: any RateLimiterSleeper = TaskRateLimiterSleeper()) {
        self.defaultInterval = defaultInterval
        self.rules = rules
        self.clock = clock
        self.sleeper = sleeper
    }

    func reserve(sourceID: QualifiedSourceID, origin: String, path: String) async throws {
        let matchingRules = rules.filter { $0.origin == origin && path.hasPrefix($0.pathPrefix) }
        var reservations: [RateLimiterReservation] = []
        do {
            // Reserve the stricter path budget first, so a request waiting on it does not
            // consume an origin slot that cannot yet be used.
            for rule in matchingRules {
                let pathLimiter = limiter(sourceID: sourceID, origin: origin,
                                          pathPrefix: rule.pathPrefix, interval: rule.interval)
                reservations.append(try await pathLimiter.acquire())
            }
            let originLimiter = limiter(sourceID: sourceID, origin: origin,
                                        pathPrefix: nil, interval: defaultInterval)
            reservations.append(try await originLimiter.acquire())
            try Task.checkCancellation()
        } catch {
            for reservation in reservations { await reservation.cancel() }
            throw error
        }
    }

    private func limiter(sourceID: QualifiedSourceID, origin: String,
                         pathPrefix: String?, interval: TimeInterval) -> RateLimiter {
        let key = LimiterKey(sourceID: sourceID, origin: origin, pathPrefix: pathPrefix)
        if let existing = limiters[key] { return existing }
        let created = RateLimiter(minimumInterval: interval, clock: clock, sleeper: sleeper)
        limiters[key] = created
        return created
    }
}
