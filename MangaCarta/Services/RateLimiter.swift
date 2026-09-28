import Foundation

protocol RateLimiterClock: Sendable {
    func now() -> Date
}

struct SystemRateLimiterClock: RateLimiterClock {
    func now() -> Date { Date() }
}

protocol RateLimiterSleeper: Sendable {
    func sleep(until: Date) async throws
}

struct TaskRateLimiterSleeper: RateLimiterSleeper {
    func sleep(until date: Date) async throws {
        let delay = date.timeIntervalSinceNow
        guard delay > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }
}

/// A spacing limiter whose reservations are made before the first suspension point.
/// A reservation that is cancelled while waiting can be returned to the budget.
/// A pause holds every slot until it ends, including slots already handed to sleeping waiters.
actor RateLimiter {
    private let minimumInterval: TimeInterval
    private let clock: any RateLimiterClock
    private let sleeper: any RateLimiterSleeper
    private var nextSlot: Date?
    private var releasedSlots: [Date] = []
    private var pausedUntil: Date?

    init(minimumInterval: TimeInterval,
         clock: any RateLimiterClock = SystemRateLimiterClock(),
         sleeper: any RateLimiterSleeper = TaskRateLimiterSleeper()) {
        self.minimumInterval = minimumInterval
        self.clock = clock
        self.sleeper = sleeper
    }

    func acquire(ignoringCancellation: Bool = false) async throws -> RateLimiterReservation {
        var slot = reserveSlot()
        do {
            try await sleeper.sleep(until: slot)
            while let pausedUntil, slot < pausedUntil {
                // A pause began while this waiter slept. Take a fresh slot after it, so the
                // waiters it held are still spaced rather than released together.
                slot = reserveSlot()
                try await sleeper.sleep(until: slot)
            }
            return RateLimiterReservation(limiter: self, slot: slot)
        } catch is CancellationError where ignoringCancellation {
            // AniList historically ran the operation after a cancelled wait.
            // Keep its reservation spent so a later caller is still spaced.
            return RateLimiterReservation(limiter: self, slot: slot)
        } catch {
            release(slot: slot)
            throw error
        }
    }

    /// Holds every reservation until `date`. A later pause extends an earlier one; an earlier
    /// one never shortens it.
    func pause(until date: Date) {
        guard date > (pausedUntil ?? .distantPast) else { return }
        pausedUntil = date
        nextSlot = max(nextSlot ?? date, date)
        releasedSlots.removeAll { $0 < date }
    }

    private func reserveSlot() -> Date {
        let earliest = max(clock.now(), pausedUntil ?? .distantPast)
        releasedSlots.removeAll { $0 < earliest }
        if !releasedSlots.isEmpty {
            return releasedSlots.removeFirst()
        }
        let slot = max(earliest, nextSlot ?? earliest)
        nextSlot = slot.addingTimeInterval(minimumInterval)
        return slot
    }

    fileprivate func release(slot: Date) {
        guard let nextSlot else { return }
        let earliest = max(clock.now(), pausedUntil ?? .distantPast)
        if slot.addingTimeInterval(minimumInterval) == nextSlot {
            self.nextSlot = max(earliest, slot)
        } else if slot >= earliest {
            // A queued waiter may be behind this one. Reuse the empty slot
            // without moving that later waiter's reservation.
            let insertionIndex = releasedSlots.firstIndex { $0 > slot } ?? releasedSlots.endIndex
            releasedSlots.insert(slot, at: insertionIndex)
        }
    }
}

struct RateLimiterReservation: Sendable {
    private let limiter: RateLimiter
    private let slot: Date
    private let state: ReservationState

    fileprivate init(limiter: RateLimiter, slot: Date) {
        self.limiter = limiter
        self.slot = slot
        self.state = ReservationState()
    }

    /// Returns the slot only for cancellation while waiting for a larger set of budgets.
    func cancel() async {
        guard await state.claimCancellation() else { return }
        await limiter.release(slot: slot)
    }
}

private actor ReservationState {
    private var cancelled = false
    func claimCancellation() -> Bool {
        guard !cancelled else { return false }
        cancelled = true
        return true
    }
}
