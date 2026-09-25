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
actor RateLimiter {
    private let minimumInterval: TimeInterval
    private let clock: any RateLimiterClock
    private let sleeper: any RateLimiterSleeper
    private var nextSlot: Date?
    private var releasedSlots: [Date] = []

    init(minimumInterval: TimeInterval,
         clock: any RateLimiterClock = SystemRateLimiterClock(),
         sleeper: any RateLimiterSleeper = TaskRateLimiterSleeper()) {
        self.minimumInterval = minimumInterval
        self.clock = clock
        self.sleeper = sleeper
    }

    func acquire(ignoringCancellation: Bool = false) async throws -> RateLimiterReservation {
        let now = clock.now()
        releasedSlots.removeAll { $0 < now }
        let slot: Date
        if !releasedSlots.isEmpty {
            slot = releasedSlots.removeFirst()
        } else {
            slot = max(now, nextSlot ?? now)
            nextSlot = slot.addingTimeInterval(minimumInterval)
        }
        do {
            try await sleeper.sleep(until: slot)
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

    fileprivate func release(slot: Date) {
        guard let nextSlot else { return }
        if slot.addingTimeInterval(minimumInterval) == nextSlot {
            self.nextSlot = max(clock.now(), slot)
        } else if slot >= clock.now() {
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
