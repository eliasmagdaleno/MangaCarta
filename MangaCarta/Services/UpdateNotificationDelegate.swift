import Foundation
import UserNotifications

/// The app's `UNUserNotificationCenterDelegate`, set at launch. A tapped new-chapter
/// notification is handed to the notifier, which routes it to the Work (ADR-0021).
@MainActor
final class UpdateNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    /// The foreground pass posts too, so its notifications are shown while the app is open.
    nonisolated static let foregroundPresentationOptions: UNNotificationPresentationOptions = [.banner, .list]

    private let handleResponse: ([AnyHashable: Any]) -> Void
    private let handleAction: (String, [AnyHashable: Any], @escaping () -> Void) -> Void

    init(handleResponse: @escaping ([AnyHashable: Any]) -> Void,
         handleAction: @escaping (String, [AnyHashable: Any], @escaping () -> Void) -> Void = { _, _, completion in completion() }) {
        self.handleResponse = handleResponse
        self.handleAction = handleAction
    }

    /// What `didReceive` does with a tapped notification's payload; its own method because a
    /// `UNNotificationResponse` cannot be built in a test.
    func receive(userInfo: [AnyHashable: Any]) {
        handleResponse(userInfo)
    }

    func receive(actionIdentifier: String, userInfo: [AnyHashable: Any], completion: @escaping () -> Void) {
        if actionIdentifier == UNNotificationDefaultActionIdentifier {
            handleResponse(userInfo)
            completion()
        } else {
            handleAction(actionIdentifier, userInfo, completion)
        }
    }

    // The center calls both on the main thread.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        MainActor.assumeIsolated {
            receive(actionIdentifier: response.actionIdentifier, userInfo: userInfo,
                    completion: completionHandler)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler:
                                            @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(Self.foregroundPresentationOptions)
    }
}
