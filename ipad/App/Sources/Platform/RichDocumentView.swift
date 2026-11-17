import SwiftUI
import WebKit
import CryptoKit

/// Complex formulae, diagrams and notation use a bundled network-isolated
/// renderer. Ordinary paragraphs stay in the native selectable text surface.
struct RichDocumentView: UIViewRepresentable {
    let text: String
    let isNight: Bool
    @Binding var contentHeight: CGFloat
    var fontSize: CGFloat = 17
    var isIncomplete = false
    var onSelectionChange: (() -> Void)?
    var onOpenSource: ((URL) -> Bool)?
    @Environment(\.openURL) private var openURL

    static func prewarm() { RichPagePool.shared.prewarm() }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> RichPageContainer {
        let container = RichPageContainer()
        let page = RichPagePool.shared.acquire()
        context.coordinator.page = page
        page.owner = context.coordinator
        container.install(page.webView)
        container.widthChanged = { [weak coordinator = context.coordinator] width in coordinator?.layout(width: width) }
        return container
    }

    func updateUIView(_ view: RichPageContainer, context: Context) {
        view.pencilPreview = PencilPreview(title: "排版手稿", text: text)
        context.coordinator.parent = self
        context.coordinator.layout(width: view.bounds.width)
    }

    static func dismantleUIView(_ view: RichPageContainer, coordinator: Coordinator) {
        view.widthChanged = nil
        if let page = coordinator.page {
            page.owner = nil
            page.webView.removeFromSuperview()
            RichPagePool.shared.release(page)
        }
        coordinator.page = nil
    }

    @MainActor final class Coordinator: RichPageOwner {
        var parent: RichDocumentView
        fileprivate var page: RichPage?
        private var cacheKey = ""
        private var width: CGFloat = 0
        private var renderID = ""
        init(_ parent: RichDocumentView) { self.parent = parent }
        func layout(width: CGFloat) {
            guard width.isFinite, width > 1, let page else { return }
            self.width = width
            let digest = SHA256.hash(data: Data(parent.text.utf8)).map { String(format: "%02x", $0) }.joined()
            let key = "web-v2:\(digest):\(Int((width * 2).rounded())):\(parent.isNight):\(parent.fontSize):\(parent.isIncomplete)"
            guard key != cacheKey else { return }
            cacheKey = key; renderID = UUID().uuidString
            if let cached = MessageMeasuredHeights.shared.value(for: key) { setHeight(cached, for: renderID) }
            let payload: [String: Any] = ["text": parent.text, "theme": parent.isNight ? "night" : "day", "fontSize": Double(parent.fontSize),
                                          "incomplete": parent.isIncomplete, "renderID": renderID]
            page.render(payload)
        }
        func receive(_ value: [String: Any]) {
            guard value["renderID"] as? String == renderID, let kind = value["kind"] as? String else { return }
            if kind == "height", let height = value["value"] as? Double, height.isFinite, height > 0,
               let measuredWidth = value["width"] as? Double, abs(measuredWidth - Double(width)) < 2 {
                MessageMeasuredHeights.shared.insert(CGFloat(height), for: cacheKey)
                setHeight(CGFloat(height), for: renderID)
            }
            if kind == "copy", let text = value["value"] as? String { UIPasteboard.general.string = text }
            if kind == "selection" { parent.onSelectionChange?() }
            if kind == "link", let address = value["value"] as? String, let url = URL(string: address) {
                if parent.onOpenSource?(url) == true { return }
                if url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil {
                    parent.openURL(url)
                }
            }
            if kind == "anchor", let top = value["top"] as? Double, let targetHeight = value["height"] as? Double,
               top.isFinite, targetHeight.isFinite, top >= 0, top <= Double(parent.contentHeight), let webView = page?.webView {
                parent.onSelectionChange?()
                var ancestor = webView.superview
                while let candidate = ancestor {
                    if let scroll = candidate as? UIScrollView, scroll.isScrollEnabled {
                        let area = webView.convert(CGRect(x: 0, y: CGFloat(top), width: webView.bounds.width, height: CGFloat(max(24, min(150, targetHeight)))), to: scroll)
                        scroll.scrollRectToVisible(area.insetBy(dx: 0, dy: -16), animated: !UIAccessibility.isReduceMotionEnabled)
                        break
                    }
                    ancestor = candidate.superview
                }
            }
        }
        private func setHeight(_ height: CGFloat, for identifier: String) {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.renderID == identifier, abs(self.parent.contentHeight - height) > 0.5 else { return }
                self.parent.contentHeight = height
            }
        }
    }
}

@MainActor
fileprivate protocol RichPageOwner: AnyObject {
    func receive(_ value: [String: Any])
}

/// The current file owns one scrollable renderer across inspector layouts.
/// Its DOM, table offsets and source mode survive reparenting.
@MainActor
final class MarkdownDocumentSession: ObservableObject, RichPageOwner {
    @Published var showsSource = false
    @Published private(set) var isLoading = true
    private var page: RichPage?
    private var key = ""
    private var identifier = ""
    private var documentHeight: CGFloat = 0
    private var measuredWidth: CGFloat = 0
    private weak var container: RichPageContainer?
    private var positions: [String: CGPoint] = [:]
    private var needsPositionRestore = false
    private var contentSizeObservation: NSKeyValueObservation?
    private var onOpenURL: ((URL) -> Void)?

    fileprivate func attach(to container: RichPageContainer) {
        if page == nil {
            let page = RichPage(scrolling: true)
            page.owner = self; self.page = page
            contentSizeObservation = page.webView.scrollView.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.restorePositionIfReady() }
            }
        }
        guard let page else { return }
        self.container = container; needsPositionRestore = true
        container.willChangeSize = { [weak self] in self?.rememberPosition() }
        container.widthChanged = { [weak self] _ in self?.restorePositionIfReady() }
        container.install(page.webView)
        page.webView.setAllMediaPlaybackSuspended(false)
    }

    fileprivate func configure(text: String, night: Bool, fontSize: CGFloat, onOpenURL: @escaping (URL) -> Void) {
        self.onOpenURL = onOpenURL
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        let next = "\(digest):\(night):\(fontSize)"
        guard next != key, let page else { return }
        key = next; identifier = UUID().uuidString
        publishLoading(true)
        page.render(["text": text, "theme": night ? "night" : "day", "fontSize": Double(fontSize),
                     "renderID": identifier, "preserveViewport": true])
    }

    fileprivate func detach(from container: RichPageContainer) {
        guard let page, page.webView.superview === container else { return }
        rememberPosition()
        container.willChangeSize = nil; container.widthChanged = nil
        page.webView.setAllMediaPlaybackSuspended(true)
        page.webView.removeFromSuperview(); onOpenURL = nil; self.container = nil
    }

    func receive(_ value: [String: Any]) {
        guard value["renderID"] as? String == identifier, let kind = value["kind"] as? String else { return }
        if kind == "height", let height = value["value"] as? Double, height.isFinite, height > 0 {
            documentHeight = CGFloat(height)
            if let width = value["width"] as? Double, width.isFinite { measuredWidth = CGFloat(width) }
            publishLoading(false); restorePositionIfReady()
        }
        if kind == "copy", let text = value["value"] as? String { UIPasteboard.general.string = text }
        if kind == "link", let address = value["value"] as? String, let url = URL(string: address) { onOpenURL?(url) }
        if kind == "anchor", let top = value["top"] as? Double, let height = value["height"] as? Double,
           top.isFinite, height.isFinite, top >= 0, top <= Double(documentHeight), let page {
            page.webView.scrollView.scrollRectToVisible(
                CGRect(x: 0, y: CGFloat(top), width: page.webView.bounds.width, height: CGFloat(max(24, min(150, height)))),
                animated: !UIAccessibility.isReduceMotionEnabled)
        }
    }

    private func publishLoading(_ value: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isLoading != value else { return }
            self.isLoading = value
        }
    }

    private func viewportKey(_ size: CGSize) -> String {
        "\(Int((size.width * 2).rounded())):\(Int((size.height * 2).rounded()))"
    }
    private func rememberPosition() {
        guard !needsPositionRestore, documentHeight > 0, let page,
              page.webView.bounds.width > 1, page.webView.bounds.height > 1 else { return }
        positions[viewportKey(page.webView.bounds.size)] = page.webView.scrollView.contentOffset
        needsPositionRestore = true
    }
    private func restorePositionIfReady() {
        guard needsPositionRestore, let page, let container, container.window != nil,
              page.webView.superview === container, page.webView.bounds.width > 1,
              abs(page.webView.bounds.width - measuredWidth) < 2 else { return }
        let key = viewportKey(page.webView.bounds.size)
        guard let position = positions[key] else { needsPositionRestore = false; return }
        let scroll = page.webView.scrollView
        // The DOM reports its new width before WKScrollView necessarily adopts
        // the new content size. Keep the saved offset until that commit arrives.
        let requiredHeight = min(documentHeight * scroll.zoomScale, max(0, position.y) + scroll.bounds.height)
        guard scroll.contentSize.height + 1 >= requiredHeight else { return }
        needsPositionRestore = false
        DispatchQueue.main.async { [weak self, weak container] in
            guard let self, let container, self.container === container, let page = self.page,
                  self.viewportKey(page.webView.bounds.size) == key else { return }
            let scroll = page.webView.scrollView
            let requiredHeight = min(self.documentHeight * scroll.zoomScale, max(0, position.y) + scroll.bounds.height)
            guard scroll.contentSize.height + 1 >= requiredHeight else { self.needsPositionRestore = true; return }
            let bottom = max(0, scroll.contentSize.height - scroll.bounds.height)
            scroll.setContentOffset(CGPoint(x: 0, y: min(bottom, max(0, position.y))), animated: false)
        }
    }

    deinit {
        if let page { Task { @MainActor in page.dispose() } }
    }
}

struct MarkdownDocumentView: UIViewRepresentable {
    let session: MarkdownDocumentSession
    let text: String
    let isNight: Bool
    let fontSize: CGFloat
    var onOpenSource: ((URL) -> Bool)?
    @Environment(\.openURL) private var openURL

    @MainActor final class Coordinator {
        let session: MarkdownDocumentSession
        init(_ session: MarkdownDocumentSession) { self.session = session }
    }
    func makeCoordinator() -> Coordinator { Coordinator(session) }
    func makeUIView(context: Context) -> RichPageContainer {
        let view = RichPageContainer(); session.attach(to: view); return view
    }
    func updateUIView(_ view: RichPageContainer, context: Context) {
        view.pencilPreview = PencilPreview(title: "笔记手稿", text: text)
        let handler = onOpenSource, opener = openURL
        session.configure(text: text, night: isNight, fontSize: fontSize) { url in
            if handler?(url) == true { return }
            if url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil { opener(url) }
        }
    }
    static func dismantleUIView(_ view: RichPageContainer, coordinator: Coordinator) {
        coordinator.session.detach(from: view)
    }
}

final class RichPageContainer: UIView, PencilPreviewProviding {
    var pencilPreview: PencilPreview?
    var widthChanged: ((CGFloat) -> Void)?
    var willChangeSize: (() -> Void)?
    private var layoutSize = CGSize.zero
    func install(_ webView: WKWebView) {
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([webView.leadingAnchor.constraint(equalTo: leadingAnchor), webView.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     webView.topAnchor.constraint(equalTo: topAnchor), webView.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }
    override func layoutSubviews() {
        if layoutSize != bounds.size { willChangeSize?() }
        super.layoutSubviews()
        layoutSize = bounds.size; widthChanged?(bounds.width)
    }
    override func didMoveToWindow() { super.didMoveToWindow(); widthChanged?(bounds.width) }
}

/// Bounded *idle* view reuse; live islands remain independent interactive views.
/// This does not claim a fixed WebKit process count or a measured memory ceiling.
@MainActor
private final class RichPagePool: NSObject {
    static let shared = RichPagePool()
    private var idle: [RichPage] = []
    private let capacity = 2
    private var warmed = false
    private override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(purge), name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
    }
    func prewarm() {
        guard !warmed else { return }
        warmed = true
        idle.append(RichPage())
    }
    func acquire() -> RichPage { idle.popLast() ?? RichPage() }
    func release(_ page: RichPage) {
        page.reset()
        if idle.count < capacity { idle.append(page) } else { page.dispose() }
    }
    @objc private func purge() { idle.forEach { $0.dispose() }; idle.removeAll(); warmed = false }
}

@MainActor
fileprivate final class RichPage: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    // All islands load the same offline renderer and receive no credentials.
    // Share its ephemeral store rather than creating an isolated store per formula.
    private static let rendererStore = WKWebsiteDataStore.nonPersistent()
    let webView: WKWebView
    weak var owner: (any RichPageOwner)?
    private var ready = false
    private var pending: [String: Any]?
    private let rendererURL: URL?
    init(scrolling: Bool = false) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = Self.rendererStore
        if scrolling { configuration.preferences.inactiveSchedulingPolicy = .suspend }
        webView = WKWebView(frame: .zero, configuration: configuration)
        rendererURL = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Renderer")
        super.init()
        configuration.userContentController.add(self, name: "haji")
        webView.isOpaque = false; webView.backgroundColor = .clear
        webView.isHidden = true
        webView.scrollView.backgroundColor = .clear; webView.scrollView.isScrollEnabled = scrolling
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.navigationDelegate = self
        if let rendererURL { webView.loadFileURL(rendererURL, allowingReadAccessTo: rendererURL.deletingLastPathComponent()) }
    }
    func render(_ payload: [String: Any]) { pending = payload; submit() }
    private func submit() {
        guard ready, let pending, let data = try? JSONSerialization.data(withJSONObject: pending),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("void window.loadDocument(\(json))", completionHandler: nil)
    }
    func reset() {
        owner = nil; pending = nil
        webView.isHidden = true
        if ready { webView.evaluateJavaScript("void window.clearDocument()", completionHandler: nil) }
    }
    func dispose() {
        reset(); webView.stopLoading(); webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "haji")
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let value = message.body as? [String: Any] else { return }
        if value["kind"] as? String == "ready" { ready = true; submit() }
        else {
            if value["kind"] as? String == "height", let identifier = value["renderID"] as? String,
               let expected = pending?["renderID"] as? String, identifier == expected {
                webView.isHidden = false
            }
            owner?.receive(value)
        }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ready = false
        webView.isHidden = true
        if let rendererURL { webView.loadFileURL(rendererURL, allowingReadAccessTo: rendererURL.deletingLastPathComponent()) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.request.url == rendererURL && navigationAction.navigationType == .other { decisionHandler(.allow) }
        else { decisionHandler(.cancel) }
    }
}
