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

/// When a server says a client may send again: a delay in seconds, or an instant.
enum HostRetryAfter: Sendable, Equatable {
    case delay(TimeInterval)
    case instant(Date)

    /// No plausible delay is a billion seconds (about 31 years), and every Unix time since
    /// 2001 is larger than that. So a bare number above it is an epoch instant, as in MangaDex's
    /// `X-RateLimit-Retry-After`, and anything smaller is seconds, as in RFC 9110 `Retry-After`.
    private static let epochThreshold: Double = 1_000_000_000

    init?(headerValue: String) {
        let raw = headerValue.trimmingCharacters(in: .whitespaces)
        if let number = Double(raw) {
            guard number.isFinite, number >= 0 else { return nil }
            self = number > Self.epochThreshold
                ? .instant(Date(timeIntervalSince1970: number))
                : .delay(number)
            return
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        guard let date = formatter.date(from: raw) else { return nil }
        self = .instant(date)
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
    /// A malformed or hostile header must not lock a Source out for long.
    static let maximumPause: TimeInterval = 300
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

    /// Holds every budget this Source has for `origin` (the origin one and any path ones)
    /// until the server's retry time, capped at `maximumPause`.
    func pause(sourceID: QualifiedSourceID, origin: String, retryAfter: HostRetryAfter) async {
        let now = clock.now()
        let requested: Date
        switch retryAfter {
        case .delay(let seconds): requested = now.addingTimeInterval(seconds)
        case .instant(let date): requested = date
        }
        let until = min(requested, now.addingTimeInterval(Self.maximumPause))
        guard until > now else { return }
        _ = limiter(sourceID: sourceID, origin: origin, pathPrefix: nil, interval: defaultInterval)
        let affected = limiters.filter { $0.key.sourceID == sourceID && $0.key.origin == origin }
        for limiter in affected.values {
            await limiter.pause(until: until)
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
