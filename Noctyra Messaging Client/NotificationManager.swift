import Foundation
import UserNotifications

@MainActor
final class NotificationManager {
    private var isAuthorized = false
    private var didRequest = false

    func requestAuthorization() async {
        guard !didRequest else { return }
        didRequest = true
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            isAuthorized = granted
        } catch {
            isAuthorized = false
        }
    }

    func notifyNewMessage() {
        guard isAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "Noctyra"
        content.body = "A new encrypted message is ready."
        content.sound = .default
        content.threadIdentifier = "noctyra-encrypted-message"
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
