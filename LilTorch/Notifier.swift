import BackgroundTasks
import Foundation
import TorchKit
import UIKit
import UserNotifications

enum Notifier {
    static let refreshTaskID = "liltorch.refresh"

    /// Asks once; on approval, also asks iOS for an APNs token.
    @MainActor
    static func requestAuthorization() async {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        if granted {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    /// The local fallback for agents that can't push (no APNs key yet).
    static func post(_ event: AgentEvent, from agent: AgentRecord) {
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = event.body
        content.sound = .default
        content.threadIdentifier = event.kind
        content.userInfo = ["agent": agent.id.uuidString, "seq": event.seq]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "\(agent.id)-\(event.seq)", content: content, trigger: nil))
    }

    /// iOS decides when this actually runs; 15 minutes is a hint, not a schedule.
    static func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
