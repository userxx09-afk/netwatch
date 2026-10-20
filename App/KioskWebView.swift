import NetWatchKit
import SwiftUI
import WebKit

/// Full-screen web kiosk with load-failure logging and automatic retry.
struct KioskWebView: UIViewRepresentable {
    let url: URL
    let reloadToken: Int
    let onSecretGesture: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = context.coordinator

        let press = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.secretPress(_:)))
        press.numberOfTouchesRequired = 3
        press.minimumPressDuration = 3
        press.cancelsTouchesInView = false
        webView.addGestureRecognizer(press)

        context.coordinator.lastToken = reloadToken
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        if reloadToken != context.coordinator.lastToken {
            context.coordinator.lastToken = reloadToken
            NetWatch.shared.log("kiosk_reload", "Reloading kiosk page after connectivity was restored")
            webView.load(URLRequest(url: url))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: KioskWebView
        var lastToken = 0
        private var retry: DispatchWorkItem?

        init(_ parent: KioskWebView) { self.parent = parent }

        @objc func secretPress(_ gesture: UILongPressGestureRecognizer) {
            if gesture.state == .began { parent.onSecretGesture() }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            NetWatch.shared.log("kiosk_loaded", "Kiosk page loaded", data: ["url": webView.url?.absoluteString ?? ""])
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            failed(webView, error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            failed(webView, error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            NetWatch.shared.log("kiosk_webcontent_crashed", "Web content process terminated (blank screen); reloading", level: .error)
            webView.reload()
        }

        private func failed(_ webView: WKWebView, _ error: Error) {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
            NetWatch.shared.log("kiosk_load_failed", "Kiosk page failed to load: \(ns.localizedDescription); retrying in 15s",
                                level: .warn, data: ["code": ns.code, "domain": ns.domain])
            retry?.cancel()
            let url = parent.url
            let item = DispatchWorkItem { [weak webView] in webView?.load(URLRequest(url: url)) }
            retry = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: item)
        }
    }
}
