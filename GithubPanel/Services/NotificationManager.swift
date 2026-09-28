import Foundation
import UserNotifications
import AppKit

protocol NotificationPosting {
    func postStatusNotification(state: CheckState,
                                title: String,
                                repoFullName: String,
                                number: Int,
                                htmlURL: URL)
    func postPullRequestNotification(_ notification: PullRequestNotification)
}

final class NotificationManager: NSObject, UNUserNotificationCenterDelegate, NotificationPosting {
    static let shared = NotificationManager()

    /// Shows a clicked notification's pull request in the app. Returns false when no window can show it,
    /// and the pull request opens on GitHub instead.
    var openPullRequest: (@MainActor (PullRequestReference) -> Bool)?

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
        content.userInfo = Self.userInfo(for: PullRequestReference(repoFullName: repoFullName, number: number), htmlURL: htmlURL)
        post(content)
    }

    func postPullRequestNotification(_ notification: PullRequestNotification) {
        let content = UNMutableNotificationContent()
        content.title = notification.heading
        content.body = notification.body
        content.sound = .default
        content.userInfo = Self.userInfo(for: notification.reference, htmlURL: notification.htmlURL)
        post(content)
    }

    private func post(_ content: UNNotificationContent) {
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    static func userInfo(for reference: PullRequestReference, htmlURL: URL) -> [String: Any] {
        ["url": htmlURL.absoluteString, "repo": reference.repoFullName, "number": reference.number]
    }

    /// The pull request a notification is about. Nil for notifications posted before they carried one.
    static func reference(from userInfo: [AnyHashable: Any]) -> PullRequestReference? {
        guard let repo = userInfo["repo"] as? String, let number = userInfo["number"] as? Int else { return nil }
        return PullRequestReference(repoFullName: repo, number: number)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        let reference = Self.reference(from: userInfo)
        let url = (userInfo["url"] as? String).flatMap(URL.init(string:))
        let openPullRequest = openPullRequest
        Task { @MainActor in
            if let reference, let openPullRequest, openPullRequest(reference) { return }
            if let url {
                NSWorkspace.shared.open(url)
            }
        }
        completionHandler()
    }
}
