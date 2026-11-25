import SwiftUI
import UserNotifications

private final class CoralcordNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = CoralcordNotificationDelegate()

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .badge])
    }
}

@main
struct CordialApp: App {
    @StateObject private var model = ChatModel()
    @AppStorage("appearanceMode") private var appearanceMode = "light"

    init() {
        UNUserNotificationCenter.current().delegate = CoralcordNotificationDelegate.shared
    }

    var body: some Scene {
        WindowGroup {
            InboxView()
                .environmentObject(model)
                .preferredColorScheme(appearanceMode == "dark" ? .dark : .light)
        }
    }
}
