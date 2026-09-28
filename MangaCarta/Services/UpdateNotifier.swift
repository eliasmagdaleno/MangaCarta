import Foundation
import UserNotifications

@MainActor
protocol NotificationScheduling {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async -> Bool
    func add(_ request: UNNotificationRequest) async
    func removePending(withIdentifiers identifiers: [String])
}

struct UNUserNotificationCenterAdapter: NotificationScheduling {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) == true
    }

    func add(_ request: UNNotificationRequest) async {
        try? await center.add(request)
    }

    func removePending(withIdentifiers identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}

enum NotificationAuthorizationSummary: Equatable {
    case notRequested
    case enabled
    case unavailable
}

@MainActor
final class UpdateNotifier {
    static let requestedAuthorizationKey = "updates.hasRequestedNotificationAuthorization"
    static let notificationsEnabledKey = "updates.notificationsEnabled"
    static let workIdUserInfoKey = "workId"
    static let threadIdentifier = "library-updates"

    private let notifications: NotificationScheduling
    private let updates: UpdateStateStore
    private let works: WorkStore
    private let library: LibraryStore
    private let registry: SourceRegistry
    private let defaults: UserDefaults
    private let openWork: (WorkID) -> Void

    init(notifications: NotificationScheduling? = nil,
         updates: UpdateStateStore,
         works: WorkStore,
         library: LibraryStore,
         registry: SourceRegistry? = nil,
         defaults: UserDefaults = .standard,
         openWork: @escaping (WorkID) -> Void = { _ in }) {
        // Nil-defaulted because the adapter's protocol conformance is @MainActor,
        // while a default argument would be evaluated from a nonisolated context.
        self.notifications = notifications ?? UNUserNotificationCenterAdapter()
        self.updates = updates
        self.works = works
        self.library = library
        self.registry = registry ?? .shared
        self.defaults = defaults
        self.openWork = openWork
    }

    func schedule(_ events: [UpdateEvent]) async {
        guard defaults.object(forKey: Self.notificationsEnabledKey) as? Bool ?? true else { return }
        guard await notifications.authorizationStatus().allowsNotifications else { return }

        for event in events where updates.state(for: event.workId)?.isMuted != true {
            let content = UNMutableNotificationContent()
            content.title = "Library Updates"
            content.body = Self.body(for: event, hidesAdultDetails: hidesAdultDetails(for: event.workId))
            content.threadIdentifier = Self.threadIdentifier
            content.userInfo = [Self.workIdUserInfoKey: event.workId.raw.uuidString]
            let request = UNNotificationRequest(
                identifier: UpdateStateStore.notificationIdentifier(for: event.workId),
                content: content,
                trigger: nil
            )
            await notifications.add(request)
        }
    }

    nonisolated static func body(for event: UpdateEvent, hidesAdultDetails: Bool = false) -> String {
        if hidesAdultDetails { return "A followed title has new chapters" }
        if event.didExceedCap { return "Many new chapters of \(event.title)" }
        if event.newChapterCount == 1 { return "1 new chapter of \(event.title)" }
        return "\(event.newChapterCount) new chapters of \(event.title)"
    }

    func requestAuthorizationIfNeeded() async {
        guard !library.items.isEmpty,
              !defaults.bool(forKey: Self.requestedAuthorizationKey),
              await notifications.authorizationStatus() == .notDetermined else { return }
        defaults.set(true, forKey: Self.requestedAuthorizationKey)
        _ = await notifications.requestAuthorization()
    }

    func authorizationSummary() async -> NotificationAuthorizationSummary {
        switch await notifications.authorizationStatus() {
        case .authorized, .provisional, .ephemeral:
            return .enabled
        case .notDetermined:
            return .notRequested
        default:
            return .unavailable
        }
    }

    func forget(workId: WorkID) {
        let identifier = updates.forget(workId: workId)
        notifications.removePending(withIdentifiers: [identifier])
    }

    func handleResponse(userInfo: [AnyHashable: Any]) {
        guard let raw = userInfo[Self.workIdUserInfoKey] as? String,
              let uuid = UUID(uuidString: raw),
              let resolved = works.work(WorkID(raw: uuid))?.id else { return }
        // Route to the Work's chapter list. A notification never opens a chapter.
        openWork(resolved)
    }

    private func hidesAdultDetails(for workId: WorkID) -> Bool {
        guard defaults.bool(forKey: AdultContentSetting.key) == false,
              let work = works.work(workId) else { return false }
        // Deliberately over-suppress when any linked Listing belongs to an adult source.
        return work.listings.contains { listing in
            registry.source(id: listing.sourceId).map {
                $0.isNSFW || $0.declaresAdultTitles
            } == true
        }
    }
}

private extension UNAuthorizationStatus {
    var allowsNotifications: Bool {
        self == .authorized || self == .provisional || self == .ephemeral
    }
}
