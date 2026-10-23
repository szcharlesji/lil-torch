import SwiftUI
import TorchKit
import UserNotifications

@main
struct LilTorchApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(delegate.model)
                .onOpenURL { url in
                    delegate.model.pendingPairing = PairingLink(url.absoluteString)
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task { await delegate.model.refresh() }
            case .background:
                Notifier.scheduleBackgroundRefresh()
            default:
                break
            }
        }
        .backgroundTask(.appRefresh(Notifier.refreshTaskID)) {
            Notifier.scheduleBackgroundRefresh()
            await delegate.model.refresh()
        }
    }
}

/// Owns the model so APNs callbacks can reach it.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor let model = AppModel()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        Task { @MainActor in
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            if settings.authorizationStatus == .authorized {
                application.registerForRemoteNotifications()
            }
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in model.didReceiveDeviceToken(deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // No push entitlement or no network: agents' events still arrive through refresh.
    }

    /// Show banners while the app is open too.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }
}
