import CryptoTickerCore
import Combine
import Foundation
import UserNotifications

@MainActor
final class AlertNotifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published private(set) var hint = L10n.text("notification.initial")
    @Published private(set) var requestingPermission = false
    private let center: UNUserNotificationCenter?

    override init() {
        // The command-line executable has no notification identity. Keep its
        // in-app alerts functional without calling current() outside an app bundle.
        center = Bundle.main.bundleURL.pathExtension == "app" ? .current() : nil
        super.init()
        center?.delegate = self
    }

    func requestPermission() async {
        guard let center else {
            hint = L10n.text("notification.packaged_hint")
            return
        }
        requestingPermission = true
        defer { requestingPermission = false }
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
            await refreshPermission()
        } catch {
            hint = L10n.text("notification.unavailable")
        }
    }

    func refreshPermission() async {
        guard let center else { return }
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            hint = L10n.text("notification.allowed")
        case .denied:
            hint = L10n.text("notification.denied")
        default:
            hint = L10n.text("notification.undetermined")
        }
    }

    func deliver(_ alert: MovementAlert, ifEnabled: @escaping @MainActor () -> Bool) async {
        await send(title: alert.title, body: alert.body, identifier: alert.id.uuidString, ifEnabled: ifEnabled)
    }

    func sendTest(ifEnabled: @escaping @MainActor () -> Bool) async {
        await send(title: L10n.text("notification.test_title"), body: L10n.text("notification.test_body"),
                   identifier: "test-\(UUID().uuidString)", ifEnabled: ifEnabled)
    }

    private func send(title: String, body: String, identifier: String,
                      ifEnabled: @escaping @MainActor () -> Bool) async {
        guard let center else {
            hint = L10n.text("notification.packaged")
            return
        }
        let settings = await center.notificationSettings()
        guard ifEnabled() else { return }
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            hint = L10n.text("notification.not_allowed")
            return
        }
        hint = L10n.text("notification.allowed")
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        do {
            try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        } catch {
            hint = L10n.text("notification.failed")
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
