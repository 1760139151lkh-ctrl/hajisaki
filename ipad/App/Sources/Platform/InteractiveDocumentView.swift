import SwiftUI
import WebKit
import CryptoKit
import os

/// One current document owns this session, so resizing/reparenting the inspector
/// preserves its DOM state. It has no bridge to the gateway, files or credentials.
@MainActor
final class InteractiveDocumentSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, UIGestureRecognizerDelegate {
    private var webView: WKWebView?
    private weak var container: InteractiveDocumentContainer?
    private var loadedDigest = ""
    private var pendingHTML = ""
    private var preparing = false
    private var ready = false
    private var failed = false
    private var night = true
    private var onFailure: (() -> Void)?
    @Published private(set) var isLoading = true
    private let log = Logger(subsystem: "app.hajisaki.theater.ipad", category: "interactive-document")

    func attach(to container: InteractiveDocumentContainer, html: String, night: Bool, onFailure: @escaping () -> Void) {
        self.container = container; container.session = self; self.onFailure = onFailure; self.night = night
        pendingHTML = html
        if let webView { container.install(webView); style(webView); submit() }
        else { prepare() }
    }

    func detach(from container: InteractiveDocumentContainer) {
        if self.container === container {
            webView?.removeFromSuperview(); self.container = nil; onFailure = nil
        }
    }

    func retryAfterFailure() {
        guard failed else { return }
        failed = false; ready = false; loadedDigest = ""
        webView?.stopLoading(); webView?.removeFromSuperview(); webView = nil
    }

    private func prepare() {
        guard !preparing, !failed else { return }
        preparing = true
        if !isLoading { isLoading = true }
        let rules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^ftp://"},"action":{"type":"block"}}]"#
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "hajisaki-interactive-offline-v1", encodedContentRuleList: rules) { [weak self] list, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.preparing = false
                guard let list else {
                    let value = error as NSError?
                    self.log.error("Rule compilation failed: \(value?.domain ?? "unknown", privacy: .public) \(value?.code ?? 0, privacy: .public) \(value?.localizedDescription ?? "", privacy: .public)")
                    self.failed = true; self.isLoading = false; self.onFailure?(); return
                }
                let configuration = WKWebViewConfiguration()
                configuration.websiteDataStore = .nonPersistent()
                configuration.defaultWebpagePreferences.allowsContentJavaScript = true
                configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
                configuration.preferences.inactiveSchedulingPolicy = .suspend
                configuration.allowsAirPlayForMediaPlayback = false
                configuration.allowsPictureInPictureMediaPlayback = false
                configuration.mediaTypesRequiringUserActionForPlayback = .all
                configuration.userContentController.add(list)
                configuration.userContentController.addUserScript(WKUserScript(source: Self.deniedPermissions, injectionTime: .atDocumentStart, forMainFrameOnly: true))
                let page = WKWebView(frame: .zero, configuration: configuration)
                page.navigationDelegate = self; page.uiDelegate = self
                page.isOpaque = false
                page.scrollView.contentInsetAdjustmentBehavior = .never
                let focus = UITapGestureRecognizer(target: nil, action: nil)
                focus.cancelsTouchesInView = false; focus.delegate = self
                page.addGestureRecognizer(focus)
                self.webView = page; self.ready = true
                self.style(page); self.container?.install(page); self.submit()
            }
        }
    }

    private func style(_ page: WKWebView) {
        let palette = TheaterPalette(isDark: night)
        page.backgroundColor = UIColor(palette.raised)
        page.scrollView.backgroundColor = UIColor(palette.raised)
        let style: UIUserInterfaceStyle = night ? .dark : .light
        if page.overrideUserInterfaceStyle != style { page.overrideUserInterfaceStyle = style }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // Enter the native responder chain before WebKit focuses the touched
        // control. Re-focusing after its click can discard the range's focus.
        if let webView, webView.window != nil { webView.becomeFirstResponder() }
        return false
    }

    private func submit() {
        guard ready, let webView else {
            if failed { DispatchQueue.main.async { [weak self] in self?.onFailure?() } }
            return
        }
        let digest = SHA256.hash(data: Data(pendingHTML.utf8)).map { String(format: "%02x", $0) }.joined()
        guard digest != loadedDigest else { return }
        loadedDigest = digest
        let html = pendingHTML
        DispatchQueue.main.async { [weak self, weak webView] in
            guard let self, let webView, self.loadedDigest == digest else { return }
            self.isLoading = true
            webView.loadHTMLString(Self.envelope(html), baseURL: nil)
        }
    }

    private static func envelope(_ source: String) -> String {
        let childPolicy = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; connect-src 'none'; media-src 'none'; frame-src 'none'; object-src 'none'; worker-src 'none'; form-action 'none'; base-uri 'none'"
        let child = "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><meta http-equiv=\"Content-Security-Policy\" content=\"\(childPolicy)\"><script>\(deniedPermissions)</script><style>:root{color-scheme:light dark}body{margin:0;font-family:-apple-system,BlinkMacSystemFont,sans-serif;overflow-wrap:anywhere}button,input,select,textarea{font:inherit}</style></head><body>" + source + "</body></html>"
        let escaped = child.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; frame-src about:; img-src data: blob:; font-src data:; connect-src 'none'; media-src 'none'; object-src 'none'; worker-src 'none'; base-uri 'none'; form-action 'none'"><style>html,body{margin:0;width:100%;height:100%;overflow:hidden;background:transparent}iframe{display:block;border:0;width:100%;height:100%;background:transparent}</style></head><body><iframe title="交互微剧场" sandbox="allow-scripts" referrerpolicy="no-referrer" allow="geolocation 'none'; camera 'none'; microphone 'none'; clipboard-read 'none'; clipboard-write 'none'; display-capture 'none'; payment 'none'; autoplay 'none'" srcdoc="\(escaped)"></iframe></body></html>
        """
    }

    private static let deniedPermissions = #"""
    (() => {
      'use strict';
      const denied = () => new DOMException('This document has no device permission.', 'NotAllowedError');
      const geo = Object.freeze({
        getCurrentPosition: (_success, error) => { if (typeof error === 'function') queueMicrotask(() => error({code:1,message:'Permission denied'})); },
        watchPosition: (_success, error) => { if (typeof error === 'function') queueMicrotask(() => error({code:1,message:'Permission denied'})); return 0; },
        clearWatch: () => {}
      });
      const fixed = (object, key, value) => { try { Object.defineProperty(object, key, {value, writable:false, configurable:false}); } catch (_) {} };
      fixed(Object.getPrototypeOf(navigator), 'geolocation', geo);
      fixed(navigator, 'geolocation', geo);
      for (const key of ['RTCPeerConnection','webkitRTCPeerConnection','WebTransport']) fixed(window, key, undefined);
      if (navigator.mediaDevices) fixed(navigator.mediaDevices, 'getUserMedia', () => Promise.reject(denied()));
      document.addEventListener('click', event => {
        if (event.target instanceof Element && event.target.closest('input[type="file"]')) event.preventDefault();
      }, true);
      const focusRange = event => {
        if (!(event.target instanceof Element)) return;
        const range = event.target.closest('input[type="range"]');
        if (!range) return;
        range.focus({preventScroll:true});
        requestAnimationFrame(() => range.focus({preventScroll:true}));
      };
      for (const name of ['pointerdown','touchend','mousedown']) document.addEventListener(name, focusRange, true);
      document.addEventListener('DOMContentLoaded', () => {
        window.addEventListener('keydown', event => {
          if (event.key !== 'Tab' || event.defaultPrevented || event.altKey || event.ctrlKey || event.metaKey) return;
          const controls = Array.from(document.querySelectorAll('button,input:not([type="hidden"]):not([type="file"]),select,textarea,a[href],[tabindex]'))
            .filter(item => item.tabIndex >= 0 && !item.disabled && !item.closest('[inert]') && item.getClientRects().length && getComputedStyle(item).visibility !== 'hidden');
          controls.sort((a,b) => (a.tabIndex || Number.MAX_SAFE_INTEGER) - (b.tabIndex || Number.MAX_SAFE_INTEGER));
          const index = controls.indexOf(document.activeElement);
          const next = index < 0 ? (event.shiftKey ? controls.length - 1 : 0) : index + (event.shiftKey ? -1 : 1);
          // Let the system leave the document at either edge; never trap Tab.
          if (next < 0 || next >= controls.length) return;
          event.preventDefault(); controls[next].focus();
        });
      }, {once:true});
      const originalClick = HTMLInputElement.prototype.click;
      fixed(HTMLInputElement.prototype, 'click', function() { if (this.type !== 'file') return originalClick.call(this); });
      const originalPicker = HTMLInputElement.prototype.showPicker;
      if (originalPicker) fixed(HTMLInputElement.prototype, 'showPicker', function() { if (this.type === 'file') throw denied(); return originalPicker.call(this); });
    })();
    """#

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        let address = url?.absoluteString.split(separator: "#", maxSplits: 1).first.map(String.init)
        let local = address == "about:blank" || address == "about:srcdoc"
        log.info("Navigation: scheme=\(url?.scheme ?? "nil", privacy: .public) path=\(url?.scheme == "about" ? (url?.path ?? "nil") : "external", privacy: .public) allowed=\(local, privacy: .public)")
        decisionHandler(local ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
    func webView(_ webView: WKWebView, requestDeviceOrientationAndMotionPermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
    @available(iOS 18.4, *)
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) { completionHandler(nil) }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) { completionHandler() }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) { completionHandler(false) }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) { completionHandler(nil) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { isLoading = false }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { failed = true; ready = false; isLoading = false; loadedDigest = ""; self.webView = nil; onFailure?() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let value = error as NSError
        log.error("Document load failed: \(value.domain, privacy: .public) \(value.code, privacy: .public)")
        if value.code == NSURLErrorCancelled || (value.domain == "WebKitErrorDomain" && value.code == 102) { return }
        isLoading = false; loadedDigest = ""; onFailure?()
    }
}

struct InteractiveDocumentView: UIViewRepresentable {
    let html: String
    let session: InteractiveDocumentSession
    let onFailure: () -> Void
    @Environment(\.theaterPalette) private var palette
    func makeUIView(context: Context) -> InteractiveDocumentContainer {
        let container = InteractiveDocumentContainer()
        session.attach(to: container, html: html, night: palette.isDark, onFailure: onFailure)
        return container
    }
    func updateUIView(_ container: InteractiveDocumentContainer, context: Context) {
        session.attach(to: container, html: html, night: palette.isDark, onFailure: onFailure)
    }
    static func dismantleUIView(_ container: InteractiveDocumentContainer, coordinator: ()) {
        container.session?.detach(from: container)
    }
}

final class InteractiveDocumentContainer: UIView {
    weak var session: InteractiveDocumentSession?
    func install(_ page: WKWebView) {
        guard page.superview !== self else { return }
        page.removeFromSuperview(); addSubview(page)
        page.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([page.leadingAnchor.constraint(equalTo: leadingAnchor), page.trailingAnchor.constraint(equalTo: trailingAnchor), page.topAnchor.constraint(equalTo: topAnchor), page.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }
}
