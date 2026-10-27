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
    /// The scheme of an extension's own pages, which extensions may open in the pane.
    static let extensionScheme = "webkit-extension"

    /// GitHub pages stay in the pane. Clicked links to other sites open in the default browser, but redirects and
    /// form posts load in the pane, so sign-in through an organization's SSO provider works.
    static func decision(for url: URL?, isLinkClick: Bool) -> WebNavigationDecision {
        guard let url, let scheme = url.scheme?.lowercased() else { return .allow }
        guard scheme == "http" || scheme == "https" else {
            return ["about", "blob", "data", extensionScheme].contains(scheme) ? .allow : .openExternally
        }
        if isGitHubHost(url.host) { return .allow }
        return isLinkClick ? .openExternally : .allow
    }

    static func isGitHubHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "github.com" || host.hasSuffix(".github.com")
    }
}

/// The one web view the GitHub pane uses. It lives as long as the window, so switching pull requests loads a new
/// page instead of building a new web view, and the github.com sign-in is kept in the default website data store.
@MainActor
final class PullRequestWebSession: NSObject, ObservableObject {
    let webView: WKWebView
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var currentURL: URL?
    /// The page last asked for by `show(_:)`, so picking the same pull request again keeps where you navigated.
    private(set) var requestedURL: URL?
    private var observations: [NSKeyValueObservation] = []

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        WebExtensions.shared.configure(configuration)
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
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
        WebExtensions.shared.didOpen(self)
    }

    /// Loads `url` unless it is already the page last asked for.
    func show(_ url: URL) {
        guard url != requestedURL else { return }
        requestedURL = url
        webView.load(URLRequest(url: url))
    }

    /// Stops loading and lets the extensions forget the web view.
    func close() {
        webView.stopLoading()
        WebExtensions.shared.didClose(self)
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }

    func openInBrowser() {
        if let url = webView.url ?? requestedURL {
            NSWorkspace.shared.open(url)
        }
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

    /// Loads the page again when its web content process ends, instead of leaving the pane blank.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if let url = webView.url ?? requestedURL {
            webView.load(URLRequest(url: url))
        }
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

/// Holds the window's `PullRequestWebSession`, made the first time the GitHub pane asks for it, so the native pane
/// never starts a web view.
@MainActor
final class LazyWebSession: ObservableObject {
    private var made: PullRequestWebSession?

    var session: PullRequestWebSession {
        if let made { return made }
        let session = PullRequestWebSession()
        made = session
        return session
    }
}

/// The selected pull request's page on github.com, under a toolbar in the title bar strip.
struct PullRequestWebPane: View {
    let reference: PullRequestReference
    let session: PullRequestWebSession
    @StateObject private var find = PageFind()

    var body: some View {
        PullRequestWebSessionView(session: session, find: find, fallbackLabel: reference.id)
            .onAppear { session.show(reference.webURL) }
            .onChange(of: reference) { newValue in session.show(newValue.webURL) }
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

/// One web view under the pane's toolbar.
private struct PullRequestWebSessionView: View {
    @ObservedObject var session: PullRequestWebSession
    @ObservedObject var find: PageFind
    let fallbackLabel: String
    @Environment(\.titleBarHeight) private var titleBarHeight
    @ObservedObject private var extensions = WebExtensions.shared

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
        .onAppear {
            find.finder = session.webView
            extensions.didActivate(session)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 0) {
                toolbarButton("chevron.left", help: "Back", action: session.goBack)
                    .disabled(!session.canGoBack)
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

            if !extensions.actionExtensions.isEmpty {
                extensionsMenu
                    .padding(.horizontal, 3)
                    .frame(height: 34)
                    .glassSurface(.control, in: Capsule())
            }

            HStack(spacing: 0) {
                toolbarButton("arrow.clockwise", help: "Reload", action: session.reload)
                toolbarButton("safari", help: "Open in Browser", action: session.openInBrowser)
            }
            .padding(.horizontal, 3)
            .frame(height: 34)
            .glassSurface(.control, in: Capsule())
        }
    }

    /// The toolbar buttons of the extensions that have one, as a menu.
    private var extensionsMenu: some View {
        Menu {
            ForEach(extensions.actionExtensions) { item in
                Button {
                    extensions.performAction(for: item.id, in: session)
                } label: {
                    if let icon = extensions.statuses[item.id]?.icon {
                        Label { Text(item.name) } icon: { Image(nsImage: icon) }
                    } else {
                        Text(item.name)
                    }
                }
            }
        } label: {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 28)
                .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Extensions")
        .accessibilityLabel("Extensions")
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
