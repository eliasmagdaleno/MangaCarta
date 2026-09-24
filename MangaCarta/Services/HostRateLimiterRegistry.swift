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
    static let defaultInterval: TimeInterval = 0.2
    static let defaultRules = [HostRateLimitRule(origin: "https://api.mangadex.org",
                                                  pathPrefix: "/at-home/server",
                                                  requestsPerMinute: 40)]

    private let defaultInterval: TimeInterval
    private let rules: [HostRateLimitRule]
    private let clock: any RateLimiterClock
    private let sleeper: any RateLimiterSleeper
    private var limiters: [String: RateLimiter] = [:]

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
        let originLimiter = limiter(key: "(sourceID.rawValue)|(origin)", interval: defaultInterval)
        var reservations: [RateLimiterReservation] = []
        do {
            reservations.append(try await originLimiter.acquire())
            for rule in rules where rule.origin == origin && path.hasPrefix(rule.pathPrefix) {
                let pathLimiter = limiter(key: "(sourceID.rawValue)|(origin)|(rule.pathPrefix)",
                                          interval: rule.interval)
                reservations.append(try await pathLimiter.acquire())
            }
            try Task.checkCancellation()
        } catch {
            for reservation in reservations { await reservation.cancel() }
            throw error
        }
    }

    private func limiter(key: String, interval: TimeInterval) -> RateLimiter {
        if let existing = limiters[key] { return existing }
        let created = RateLimiter(minimumInterval: interval, clock: clock, sleeper: sleeper)
        limiters[key] = created
        return created
    }
}
