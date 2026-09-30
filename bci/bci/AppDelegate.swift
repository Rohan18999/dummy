import UIKit

class AppDelegate: NSObject, UIApplicationDelegate {

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        print("[APNS] App didFinishLaunching")
        // Only auto-register if Push entitlements are present (paid team).
        // On personal team this will fail with aps-environment error and auto-switch to Direct MQTT.
        // Keep for experimental phase — user can also trigger manually via UI.
        // Delay slightly to let UI load before showing error.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            APNSManager.shared.register()
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        APNSManager.shared.didRegister(token: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        APNSManager.shared.didFail(error: error)
    }

    // Background remote notification handler
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable : Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        print("[APNS] didReceiveRemoteNotification with fetchCompletionHandler")
        APNSCommandProcessor.shared.handle(userInfo: userInfo, completion: completionHandler)
    }
}
