import SwiftUI
import AppKit
import WebKit

/// Where a navigation in the GitHub pane goes.
enum WebNavigationDecision: Equatable {
    /// Load it in the pane.
    case allow
    /// Hand it to the default browser and stay on the current page.
    case openExternally
}

enum WebNavigationPolicy {
    /// GitHub pages stay in the pane. Clicked links to other sites open in the default browser, but redirects and
    /// form posts load in the pane, so sign-in through an organization's SSO provider works.
    static func decision(for url: URL?, isLinkClick: Bool) -> WebNavigationDecision {
        guard let url, let scheme = url.scheme?.lowercased() else { return .allow }
        guard scheme == "http" || scheme == "https" else {
            return scheme == "about" || scheme == "blob" || scheme == "data" ? .allow : .openExternally
        }
        if isGitHubHost(url.host) { return .allow }
        return isLinkClick ? .openExternally : .allow
    }

    static func isGitHubHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "github.com" || host.hasSuffix(".github.com")
    }
}

/// One web view in the GitHub pane: a pull request's conversation or its diff. Each lives in
/// `PullRequestWebPool`, loaded before it is shown, and uses the default website data store, so the github.com
/// sign-in is shared.
@MainActor
final class PullRequestWebSession: NSObject, ObservableObject {
    static let messageHandlerName = "pullRequestPage"

    let webView: WKWebView
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var currentURL: URL?
    /// The HTTP status of the page's last main-frame response, or nil when it had none, such as for loaded HTML.
    private(set) var statusCode: Int?
    /// Whether GitHub served the page signed in, read from its `user-login` meta tag once it loads, or nil when
    /// the page has no such tag or hasn't finished loading.
    private(set) var isSignedIn: Bool?
    /// The page to load when the pool next starts this web view, or nil when nothing is waiting.
    var pendingURL: URL?
    /// Called when a click on the page asks for the pull request's other page, which another web view holds.
    var onOpenPage: ((PullRequestWebPage) -> Void)?
    /// Called when the web content process ends, so the pool can load the page again.
    var onProcessTerminated: (() -> Void)?
    /// The page last asked for by `load(_:completion:)`.
    private var requestedURL: URL?
    private var pendingNavigation: WKNavigation?
    private var loadCompletion: (() -> Void)?
    private var observations: [NSKeyValueObservation] = []

    /// `interceptedLinks` maps the paths of the pull request's other page to that page. Clicks on links to them
    /// call `onOpenPage` instead of loading here.
    init(interceptedLinks: [String: PullRequestWebPage] = [:]) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let messageProxy = ScriptMessageProxy()
        if !interceptedLinks.isEmpty {
            configuration.userContentController.addUserScript(
                WKUserScript(source: Self.linkInterceptionScript(for: interceptedLinks),
                             injectionTime: .atDocumentStart, forMainFrameOnly: true))
            configuration.userContentController.add(messageProxy, name: Self.messageHandlerName)
        }
        // A desktop-sized frame, so a page loaded before it is shown lays out as it will look.
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 900), configuration: configuration)
        super.init()
        messageProxy.session = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        observations = [
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] view, _ in
                let value = view.canGoBack
                Task { @MainActor in self?.canGoBack = value }
            },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] view, _ in
                let value = view.canGoForward
                Task { @MainActor in self?.canGoForward = value }
            },
            webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] view, _ in
                let value = view.isLoading
                Task { @MainActor in self?.isLoading = value }
            },
            webView.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] view, _ in
                let value = view.estimatedProgress
                Task { @MainActor in self?.progress = value }
            },
            webView.observe(\.url, options: [.initial, .new]) { [weak self] view, _ in
                let value = view.url
                Task { @MainActor in self?.currentURL = value }
            },
        ]
    }

    /// Loads `url`, then calls `completion` once when the load finishes or fails. A load that replaces one still
    /// running takes over its completion's place, so the earlier completion is dropped.
    func load(_ url: URL, completion: (() -> Void)? = nil) {
        requestedURL = url
        loadCompletion = completion
        pendingNavigation = webView.load(URLRequest(url: url))
        if pendingNavigation == nil { endLoad() }
    }

    /// Stops loading and drops the completion, for a web view the pool no longer keeps.
    func close() {
        pendingNavigation = nil
        loadCompletion = nil
        webView.stopLoading()
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }

    func openInBrowser() {
        if let url = webView.url ?? requestedURL {
            NSWorkspace.shared.open(url)
        }
    }

    private func endLoad(_ navigation: WKNavigation? = nil) {
        if let navigation, navigation !== pendingNavigation { return }
        pendingNavigation = nil
        let completion = loadCompletion
        loadCompletion = nil
        completion?()
    }

    fileprivate func receive(_ message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              let name = message.body as? String,
              let page = PullRequestWebPage(scriptName: name) else { return }
        onOpenPage?(page)
    }

    /// Catches clicks on links to the paths in `links` before GitHub's own handlers, and hands them to the app.
    /// Clicks with a modifier key, or on links that open elsewhere, are left to the page.
    nonisolated static func linkInterceptionScript(for links: [String: PullRequestWebPage]) -> String {
        let pages = links.mapValues(\.scriptName)
        let json = (try? JSONSerialization.data(withJSONObject: pages, options: [.sortedKeys, .withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return """
        (function () {
          var pages = \(json);
          window.addEventListener('click', function (event) {
            if (event.defaultPrevented || event.button !== 0 ||
                event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
            var link = event.target instanceof Element ? event.target.closest('a[href]') : null;
            if (!link || (link.target && link.target !== '_self')) return;
            var url = new URL(link.href, location.href);
            if (url.origin !== location.origin || url.search || url.hash) return;
            var page = pages[url.pathname.replace(/\\/+$/, '')];
            if (!page) return;
            event.preventDefault();
            event.stopImmediatePropagation();
            window.webkit.messageHandlers.\(messageHandlerName).postMessage(page);
          }, true);
        })();
        """
    }
}

extension PullRequestWebPage {
    /// The name the link interception script posts for this page.
    var scriptName: String {
        switch self {
        case .conversation: return "conversation"
        case .files: return "files"
        }
    }

    init?(scriptName: String) {
        guard let page = Self.allCases.first(where: { $0.scriptName == scriptName }) else { return nil }
        self = page
    }
}

/// Passes script messages to the session without the user content controller keeping it alive.
@MainActor
private final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var session: PullRequestWebSession?

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        session?.receive(message)
    }
}

extension PullRequestWebSession: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // Only the page itself leaves for the browser; frames inside a GitHub page load where they are.
        guard navigationAction.targetFrame?.isMainFrame ?? true else {
            decisionHandler(.allow)
            return
        }
        switch WebNavigationPolicy.decision(for: navigationAction.request.url,
                                            isLinkClick: navigationAction.navigationType == .linkActivated) {
        case .allow:
            decisionHandler(.allow)
        case .openExternally:
            decisionHandler(.cancel)
            if let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame {
            statusCode = (navigationResponse.response as? HTTPURLResponse)?.statusCode
            isSignedIn = nil
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        readSignIn()
        endLoad(navigation)
    }

    /// GitHub leaves the `user-login` meta tag empty on a page served signed out.
    private func readSignIn() {
        let script = "(document.querySelector('meta[name=\"user-login\"]') || {}).content ?? null"
        webView.evaluateJavaScript(script) { [weak self] result, _ in
            Task { @MainActor in self?.isSignedIn = (result as? String).map { !$0.isEmpty } }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        endLoad(navigation)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        endLoad(navigation)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        pendingURL = webView.url ?? requestedURL
        endLoad()
        onProcessTerminated?()
    }

    /// Links that ask for a new window: GitHub pages load in the pane, anything else opens in the browser.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            if WebNavigationPolicy.isGitHubHost(url.host) {
                webView.load(navigationAction.request)
            } else {
                NSWorkspace.shared.open(url)
            }
        }
        return nil
    }
}

/// A pull request's two web views, and which one the pane shows.
@MainActor
final class PullRequestWebPages: ObservableObject {
    let reference: PullRequestReference
    let conversation: PullRequestWebSession
    let files: PullRequestWebSession
    @Published var visiblePage: PullRequestWebPage = .conversation
    /// When GitHub last changed the pull request, as of the last load.
    var version: Date?
    /// True when GitHub changed the pull request after its pages loaded.
    var isStale = false

    init(reference: PullRequestReference, version: Date?) {
        self.reference = reference
        self.version = version
        conversation = PullRequestWebSession(interceptedLinks: Self.links(to: .files, of: reference))
        files = PullRequestWebSession(interceptedLinks: Self.links(to: .conversation, of: reference))
    }

    func session(_ page: PullRequestWebPage) -> PullRequestWebSession {
        switch page {
        case .conversation: return conversation
        case .files: return files
        }
    }

    var visibleSession: PullRequestWebSession { session(visiblePage) }

    /// The visible web view first, so it loads first.
    var sessionsInLoadOrder: [PullRequestWebSession] {
        visiblePage == .conversation ? [conversation, files] : [files, conversation]
    }

    private static func links(to page: PullRequestWebPage,
                              of reference: PullRequestReference) -> [String: PullRequestWebPage] {
        Dictionary(uniqueKeysWithValues: page.paths(for: reference).map { ($0, page) })
    }
}

/// Keeps the GitHub pane's pull requests loaded in the background, so picking one, or switching to its diff,
/// shows a page that is already there. It loads a few web views at a time, most wanted first, and drops the
/// pull requests that fall out of `PullRequestWebPreload.plan`.
@MainActor
final class PullRequestWebPool: ObservableObject {
    /// Background loads at once, so a long list doesn't send GitHub a burst of page loads.
    static let maxConcurrentLoads = 2

    private(set) var pages: [PullRequestReference: PullRequestWebPages] = [:]
    /// The pull request in the pane.
    private(set) var shown: PullRequestReference?
    /// The kept pull requests, most wanted first.
    private var priority: [PullRequestReference] = []
    private var loading: Set<ObjectIdentifier> = []

    var loadingCount: Int { loading.count }

    /// The pull request's web views, made and queued to load the first time they are asked for.
    func pages(for reference: PullRequestReference) -> PullRequestWebPages {
        if let existing = pages[reference] { return existing }
        let made = PullRequestWebPages(reference: reference, version: nil)
        for page in PullRequestWebPage.allCases {
            let session = made.session(page)
            session.pendingURL = page.url(for: reference)
            session.onOpenPage = { [weak self] page in self?.open(page, in: reference) }
            session.onProcessTerminated = { [weak self] in self?.pump() }
        }
        pages[reference] = made
        return made
    }

    /// Shows `reference` in the pane: its visible page loads now if it hasn't yet, ahead of the queue.
    func show(_ reference: PullRequestReference) {
        let previous = shown
        shown = reference
        if let previous, previous != reference, let page = pages[previous], page.isStale {
            reloadAll(page)
        }
        let page = pages(for: reference)
        loadIfNeeded(page.visiblePage, of: page)
        pump()
    }

    /// Switches the pull request's pane to `page`, loading it again if its web view went to another page.
    func open(_ page: PullRequestWebPage, in reference: PullRequestReference) {
        guard let pages = pages[reference] else { return }
        pages.visiblePage = page
        loadIfNeeded(page, of: pages)
    }

    /// Starts `page` loading now if it is waiting to, or if its web view isn't showing it: it went to another
    /// page, or GitHub answered with its sign-in page, an error, or the page as seen signed out, such as when the
    /// sign-in expired.
    private func loadIfNeeded(_ page: PullRequestWebPage, of pages: PullRequestWebPages) {
        let session = pages.session(page)
        if session.pendingURL == nil, !loading.contains(ObjectIdentifier(session)),
           !page.isShown(at: session.webView.url, statusCode: session.statusCode,
                         isSignedIn: session.isSignedIn, for: pages.reference) {
            session.pendingURL = page.url(for: pages.reference)
        }
        if session.pendingURL != nil {
            start(session)
        }
    }

    /// Keeps `candidates` loaded, in that order, and drops every other pull request except the one shown. A
    /// pull request GitHub changed since its pages loaded loads again, once it is not in the pane. No candidates
    /// drops everything, for when the pane shows the native views.
    func keep(_ candidates: [PullRequestWebCandidate]) {
        guard !candidates.isEmpty else {
            removeAll()
            return
        }
        priority = candidates.map(\.reference)
        for candidate in candidates {
            let page = pages(for: candidate.reference)
            if let version = candidate.version, version != page.version {
                page.isStale = page.version != nil
                page.version = version
            }
            if page.isStale && candidate.reference != shown {
                reloadAll(page)
            }
        }
        let kept = Set(priority).union(shown.map { [$0] } ?? [])
        for reference in pages.keys where !kept.contains(reference) {
            remove(reference)
        }
        pump()
    }

    func removeAll() {
        for reference in Array(pages.keys) {
            remove(reference)
        }
        shown = nil
        priority = []
    }

    private func remove(_ reference: PullRequestReference) {
        guard let page = pages.removeValue(forKey: reference) else { return }
        for session in [page.conversation, page.files] {
            loading.remove(ObjectIdentifier(session))
            session.close()
        }
    }

    private func reloadAll(_ page: PullRequestWebPages) {
        page.isStale = false
        for kind in PullRequestWebPage.allCases {
            page.session(kind).pendingURL = kind.url(for: page.reference)
        }
    }

    /// Starts waiting loads, most wanted first, while fewer than `maxConcurrentLoads` are running.
    private func pump() {
        let order = (shown.map { [$0] } ?? []) + priority
        for reference in order {
            guard let page = pages[reference] else { continue }
            for session in page.sessionsInLoadOrder where session.pendingURL != nil {
                guard loading.count < Self.maxConcurrentLoads else { return }
                start(session)
            }
        }
    }

    private func start(_ session: PullRequestWebSession) {
        guard let url = session.pendingURL else { return }
        session.pendingURL = nil
        let id = ObjectIdentifier(session)
        loading.insert(id)
        session.load(url) { [weak self] in
            guard let self, self.loading.remove(id) != nil else { return }
            self.pump()
        }
    }
}

/// The selected pull request's page on github.com, under a toolbar in the title bar strip.
struct PullRequestWebPane: View {
    let reference: PullRequestReference
    let pool: PullRequestWebPool
    @StateObject private var find = PageFind()

    var body: some View {
        PullRequestWebPagesView(pages: pool.pages(for: reference), pool: pool, find: find)
            .onAppear { pool.show(reference) }
            .onChange(of: reference) { newValue in pool.show(newValue) }
            .focusedSceneValue(\.pageFind, PageFindActions(show: find.show,
                                                           findNext: find.findNext,
                                                           findPrevious: find.findPrevious))
    }

    /// "acme/widgets/pull/12/files" for a github.com page, or the host and path for any other site.
    static func pathLabel(for url: URL?) -> String? {
        guard let url, let host = url.host else { return nil }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if host.lowercased() == "github.com" {
            return path.isEmpty ? host : path
        }
        return path.isEmpty ? host : "\(host)/\(path)"
    }
}

/// Shows whichever of a pull request's web views is visible.
private struct PullRequestWebPagesView: View {
    @ObservedObject var pages: PullRequestWebPages
    let pool: PullRequestWebPool
    let find: PageFind

    var body: some View {
        PullRequestWebSessionView(session: pages.visibleSession,
                                  find: find,
                                  fallbackLabel: pages.reference.id,
                                  canGoBackToConversation: pages.visiblePage == .files,
                                  goBackToConversation: { pool.open(.conversation, in: pages.reference) })
    }
}

/// One web view under the pane's toolbar.
private struct PullRequestWebSessionView: View {
    @ObservedObject var session: PullRequestWebSession
    @ObservedObject var find: PageFind
    let fallbackLabel: String
    /// True on the diff, where Back returns to the conversation once the diff's own history runs out.
    let canGoBackToConversation: Bool
    let goBackToConversation: () -> Void
    @Environment(\.titleBarHeight) private var titleBarHeight

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.leading, 28)
                .padding(.trailing, 20)
                .frame(height: max(titleBarHeight ?? 0, 54))
            if find.isVisible {
                PageFindBar(find: find)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }
            ZStack(alignment: .top) {
                WebViewHost(webView: session.webView)
                if session.isLoading {
                    ProgressView(value: session.progress)
                        .progressViewStyle(.linear)
                        .controlSize(.mini)
                        .tint(.accentColor)
                }
            }
        }
        // Find searches whichever web view is in the pane.
        .onAppear { find.finder = session.webView }
        .onChange(of: ObjectIdentifier(session)) { _ in find.finder = session.webView }
    }

    private func goBack() {
        if session.canGoBack {
            session.goBack()
        } else if canGoBackToConversation {
            goBackToConversation()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 0) {
                toolbarButton("chevron.left", help: "Back", action: goBack)
                    .disabled(!session.canGoBack && !canGoBackToConversation)
                toolbarButton("chevron.right", help: "Forward", action: session.goForward)
                    .disabled(!session.canGoForward)
            }
            .padding(.horizontal, 3)
            .frame(height: 34)
            .glassSurface(.control, in: Capsule())

            Text(PullRequestWebPane.pathLabel(for: session.currentURL) ?? fallbackLabel)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 12)

            HStack(spacing: 0) {
                toolbarButton("arrow.clockwise", help: "Reload", action: session.reload)
                toolbarButton("safari", help: "Open in Browser", action: session.openInBrowser)
            }
            .padding(.horizontal, 3)
            .frame(height: 34)
            .glassSurface(.control, in: Capsule())
        }
    }

    private func toolbarButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 28)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The bar under the toolbar that ⌘F opens: a search field, the previous and next buttons, and Done.
private struct PageFindBar: View {
    @ObservedObject var find: PageFind
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Find in Page", text: $find.query)
                    .textFieldStyle(.plain)
                    .focused($isFieldFocused)
                    .onSubmit {
                        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                            find.findPrevious()
                        } else {
                            find.findNext()
                        }
                    }
                    .onExitCommand { find.hide() }
                if find.result == .notFound {
                    Text("Not found")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .glassSurface(.control, in: Capsule())

            HStack(spacing: 0) {
                button("chevron.up", help: "Previous Match", action: find.findPrevious)
                button("chevron.down", help: "Next Match", action: find.findNext)
            }
            .padding(.horizontal, 3)
            .frame(height: 30)
            .glassSurface(.control, in: Capsule())
            .disabled(find.query.isEmpty)

            Button("Done", action: find.hide)
                .controlSize(.small)
        }
        .onAppear { isFieldFocused = true }
        .onChange(of: find.focusRequest) { _ in isFieldFocused = true }
    }

    private func button(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 24)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Puts the session's web view in the SwiftUI hierarchy without owning it, so it survives pane rebuilds.
private struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if webView.superview !== container {
            attach(to: container)
        }
    }

    /// Puts `webView` in the container in place of the one shown before, such as another pull request's.
    private func attach(to container: NSView) {
        container.subviews.forEach { $0.removeFromSuperview() }
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}
