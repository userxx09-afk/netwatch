import NetWatchKit
import SwiftUI

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        NetWatch.shared.start()
        return true
    }
}

@main
struct NetWatchApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(NetWatch.shared.status)
        }
    }
}

/// With `kioskURL` set (via MDM managed config) the app shows that page full screen,
/// so it can BE the Single App Mode app. A 3-finger press held for 3 seconds opens diagnostics.
struct RootView: View {
    @EnvironmentObject var status: NetWatchStatus
    @State private var showDiagnostics = false
    @State private var reloadToken = 0

    var body: some View {
        let kioskURL = NetWatch.shared.config.kioskURL
        Group {
            if let url = kioskURL, !showDiagnostics {
                KioskWebView(url: url, reloadToken: reloadToken) { showDiagnostics = true }
                    .ignoresSafeArea()
            } else {
                DiagnosticsView(canReturnToKiosk: kioskURL != nil) { showDiagnostics = false }
            }
        }
        .onChange(of: status.outageSince) { since in
            // Network came back: reload so the kiosk doesn't sit on an error page.
            if since == nil { reloadToken += 1 }
        }
    }
}
