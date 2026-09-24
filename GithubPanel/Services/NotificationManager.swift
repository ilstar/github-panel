import Foundation
import UserNotifications
import AppKit

protocol NotificationPosting {
    func postStatusNotification(state: CheckState,
                                title: String,
                                repoFullName: String,
                                number: Int,
                                htmlURL: URL)
}

final class NotificationManager: NSObject, UNUserNotificationCenterDelegate, NotificationPosting {
    static let shared = NotificationManager()

    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func postStatusNotification(state: CheckState,
                                title: String,
                                repoFullName: String,
                                number: Int,
                                htmlURL: URL) {
        let content = UNMutableNotificationContent()
        content.title = state == .success ? "Checks Passed" : "Checks Failed"
        content.body = "\(repoFullName)#\(number): \(title)"
        content.sound = .default
        content.userInfo = ["url": htmlURL.absoluteString]

        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let urlString = response.notification.request.content.userInfo["url"] as? String,
           let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
        completionHandler()
    }
}
