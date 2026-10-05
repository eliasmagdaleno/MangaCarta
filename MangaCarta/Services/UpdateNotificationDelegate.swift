import Foundation
import UserNotifications

/// The app's `UNUserNotificationCenterDelegate`, set at launch. A tapped new-chapter
/// notification is handed to the notifier, which routes it to the Work (ADR-0021).
@MainActor
final class UpdateNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    /// The foreground pass posts too, so its notifications are shown while the app is open.
    nonisolated static let foregroundPresentationOptions: UNNotificationPresentationOptions = [.banner, .list]

    private let handleResponse: ([AnyHashable: Any]) -> Void

    init(handleResponse: @escaping ([AnyHashable: Any]) -> Void) {
        self.handleResponse = handleResponse
    }

    /// What `didReceive` does with a tapped notification's payload; its own method because a
    /// `UNNotificationResponse` cannot be built in a test.
    func receive(userInfo: [AnyHashable: Any]) {
        handleResponse(userInfo)
    }

    // The center calls both on the main thread.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        MainActor.assumeIsolated { receive(userInfo: userInfo) }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler:
                                            @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(Self.foregroundPresentationOptions)
    }
}
