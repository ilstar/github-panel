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
    private var requestedURL: URL?
    private var observations: [NSKeyValueObservation] = []

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
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
    }

    /// Loads `url` unless it is already the page last asked for.
    func show(_ url: URL) {
        guard url != requestedURL else { return }
        requestedURL = url
        webView.load(URLRequest(url: url))
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
    @ObservedObject var session: PullRequestWebSession
    @Environment(\.titleBarHeight) private var titleBarHeight

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.leading, 28)
                .padding(.trailing, 20)
                .frame(height: max(titleBarHeight ?? 0, 54))
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
        .onAppear { session.show(reference.webURL) }
        .onChange(of: reference) { newValue in session.show(newValue.webURL) }
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

            Text(Self.pathLabel(for: session.currentURL) ?? reference.id)
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

    private func attach(to container: NSView) {
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
