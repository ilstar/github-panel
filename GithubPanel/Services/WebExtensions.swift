import AppKit
import Combine
import WebKit

/// What Settings and the pane's toolbar show for a loaded extension.
struct WebExtensionStatus: Equatable {
    var icon: NSImage?
    var hasOptionsPage = false
    var hasAction = false
    /// Why the extension didn't load.
    var error: String?
    /// The first problem WebKit found in a loaded extension, such as a manifest key it doesn't support.
    var warning: String?
}

/// Browser extensions in the GitHub.com pane. WebKit runs them from macOS 15.4; on earlier systems the list is kept
/// but nothing loads. Every pane web view is a tab to the extensions, and the main window is their one window.
@MainActor
final class WebExtensions: ObservableObject {
    static let shared = WebExtensions(library: .makeDefault())

    static var isSupported: Bool {
        if #available(macOS 15.4, *) { return true }
        return false
    }

    @Published private(set) var installed: [InstalledWebExtension]
    @Published private(set) var statuses: [String: WebExtensionStatus] = [:]
    private let library: WebExtensionLibrary
    private var host: AnyObject?

    init(library: WebExtensionLibrary) {
        self.library = library
        installed = library.extensions
        if #available(macOS 15.4, *) {
            let host = WebExtensionHost(persistent: !ProcessInfo.processInfo.isRunningTests)
            host.owner = self
            self.host = host
            Task {
                for entry in library.extensions { await self.load(entry) }
            }
        }
    }

    /// Enabled extensions with a toolbar button, for the pane's Extensions menu.
    var actionExtensions: [InstalledWebExtension] {
        installed.filter { $0.isEnabled && statuses[$0.id]?.hasAction == true }
    }

    @available(macOS 15.4, *)
    private var webKitHost: WebExtensionHost? { host as? WebExtensionHost }

    /// Lets the web views made from `configuration` run the extensions. Call before making the web view.
    func configure(_ configuration: WKWebViewConfiguration) {
        if #available(macOS 15.4, *) { webKitHost?.configure(configuration) }
    }

    func didOpen(_ session: PullRequestWebSession) {
        if #available(macOS 15.4, *) { webKitHost?.open(session) }
    }

    func didClose(_ session: PullRequestWebSession) {
        if #available(macOS 15.4, *) { webKitHost?.close(session) }
    }

    /// Tells the extensions which web view the pane shows.
    func didActivate(_ session: PullRequestWebSession) {
        if #available(macOS 15.4, *) { webKitHost?.activate(session) }
    }

    func install(from source: URL) async throws {
        let entry = try library.install(from: source)
        installed = library.extensions
        await load(entry)
    }

    func setEnabled(_ isEnabled: Bool, for id: String) async {
        guard var entry = installed.first(where: { $0.id == id }), entry.isEnabled != isEnabled else { return }
        entry.isEnabled = isEnabled
        try? library.update(entry)
        installed = library.extensions
        if isEnabled {
            await load(entry)
        } else {
            if #available(macOS 15.4, *) { webKitHost?.unload(id: id, removingData: false) }
            statuses[id] = nil
        }
    }

    func remove(id: String) {
        if #available(macOS 15.4, *) { webKitHost?.unload(id: id, removingData: true) }
        try? library.remove(id: id)
        installed = library.extensions
        statuses[id] = nil
    }

    func openOptions(for id: String) {
        if #available(macOS 15.4, *) { webKitHost?.openOptions(for: id) }
    }

    /// Clicks the extension's toolbar button for the page in `session`.
    func performAction(for id: String, in session: PullRequestWebSession) {
        if #available(macOS 15.4, *) { webKitHost?.performAction(for: id, in: session) }
    }

    /// Remembers optional permissions and sites the user allowed, so the extension keeps them after a relaunch.
    fileprivate func remember(permissions: [String], matchPatterns: [String], for id: String) {
        guard var entry = installed.first(where: { $0.id == id }) else { return }
        entry.grantedPermissions = Array(Set(entry.grantedPermissions + permissions)).sorted()
        entry.grantedMatchPatterns = Array(Set(entry.grantedMatchPatterns + matchPatterns)).sorted()
        try? library.update(entry)
        installed = library.extensions
    }

    fileprivate func name(of id: String) -> String {
        installed.first { $0.id == id }?.name ?? "The extension"
    }

    private func load(_ entry: InstalledWebExtension) async {
        guard entry.isEnabled else { return }
        guard #available(macOS 15.4, *), let host = webKitHost else { return }
        do {
            statuses[entry.id] = try await host.load(entry, from: library.directory(for: entry.id))
        } catch {
            statuses[entry.id] = WebExtensionStatus(error: error.localizedDescription)
        }
    }
}

/// Runs the extensions in WebKit's extension controller and answers its questions about tabs and windows.
@available(macOS 15.4, *)
@MainActor
final class WebExtensionHost: NSObject, WKWebExtensionControllerDelegate {
    weak var owner: WebExtensions?
    let controller: WKWebExtensionController
    private(set) var orderedTabs: [WebExtensionTab] = []
    private(set) weak var activeTab: WebExtensionTab?
    private(set) lazy var window = WebExtensionWindow(host: self)
    private var contexts: [String: WKWebExtensionContext] = [:]
    private var tabs: [ObjectIdentifier: WebExtensionTab] = [:]
    private var optionsWindows: [String: NSWindow] = [:]

    init(persistent: Bool) {
        controller = WKWebExtensionController(configuration: persistent ? .default() : .nonPersistent())
        super.init()
        controller.delegate = self
    }

    func configure(_ configuration: WKWebViewConfiguration) {
        configuration.webExtensionController = controller
    }

    /// Loads the extension and grants what its manifest asks for, since adding it was the user's choice.
    func load(_ entry: InstalledWebExtension, from directory: URL) async throws -> WebExtensionStatus {
        let webExtension = try await WKWebExtension(resourceBaseURL: directory)
        let context = WKWebExtensionContext(for: webExtension)
        // A stable identity and origin keep the extension's storage across relaunches.
        context.uniqueIdentifier = entry.id
        if let baseURL = URL(string: "webkit-extension://\(entry.id)/") {
            context.baseURL = baseURL
        }
        context.isInspectable = true
        for permission in webExtension.requestedPermissions {
            context.setPermissionStatus(.grantedExplicitly, for: permission)
        }
        for pattern in webExtension.allRequestedMatchPatterns {
            context.setPermissionStatus(.grantedExplicitly, for: pattern)
        }
        for permission in entry.grantedPermissions {
            context.setPermissionStatus(.grantedExplicitly, for: WKWebExtension.Permission(rawValue: permission))
        }
        for pattern in entry.grantedMatchPatterns.compactMap({ try? WKWebExtension.MatchPattern(string: $0) }) {
            context.setPermissionStatus(.grantedExplicitly, for: pattern)
        }
        try controller.load(context)
        contexts[entry.id] = context
        let manifest = webExtension.manifest
        return WebExtensionStatus(icon: webExtension.icon(for: NSSize(width: 32, height: 32)),
                                  hasOptionsPage: webExtension.hasOptionsPage,
                                  hasAction: ["action", "browser_action", "page_action"].contains { manifest[$0] != nil },
                                  warning: webExtension.errors.first?.localizedDescription)
    }

    func unload(id: String, removingData: Bool) {
        optionsWindows.removeValue(forKey: id)?.close()
        guard let context = contexts.removeValue(forKey: id) else { return }
        try? controller.unload(context)
        guard removingData else { return }
        let types = WKWebExtensionController.allExtensionDataTypes
        controller.fetchDataRecord(ofTypes: types, for: context) { [controller] record in
            guard let record else { return }
            controller.removeData(ofTypes: types, from: [record]) {}
        }
    }

    // MARK: Tabs

    func open(_ session: PullRequestWebSession) {
        let id = ObjectIdentifier(session)
        guard tabs[id] == nil else { return }
        let tab = WebExtensionTab(session: session, host: self)
        tabs[id] = tab
        orderedTabs.append(tab)
        controller.didOpenTab(tab)
    }

    func close(_ session: PullRequestWebSession) {
        guard let tab = tabs.removeValue(forKey: ObjectIdentifier(session)) else { return }
        orderedTabs.removeAll { $0 === tab }
        if activeTab === tab { activeTab = nil }
        controller.didCloseTab(tab, windowIsClosing: false)
    }

    func activate(_ session: PullRequestWebSession) {
        guard let tab = tabs[ObjectIdentifier(session)], tab !== activeTab else { return }
        let previous = activeTab
        activeTab = tab
        controller.didActivateTab(tab, previousActiveTab: previous)
    }

    fileprivate func tabChanged(_ tab: WebExtensionTab, _ properties: WKWebExtension.TabChangedProperties) {
        guard tabs.values.contains(where: { $0 === tab }) else { return }
        controller.didChangeTabProperties(properties, for: tab)
    }

    func performAction(for id: String, in session: PullRequestWebSession) {
        guard let context = contexts[id] else { return }
        context.performAction(for: tabs[ObjectIdentifier(session)] ?? activeTab)
    }

    func openOptions(for id: String) {
        if let existing = optionsWindows[id] {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        guard let context = contexts[id], let url = context.optionsPageURL,
              let configuration = context.webViewConfiguration else { return }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 720, height: 560), configuration: configuration)
        webView.load(URLRequest(url: url))
        let window = NSWindow(contentRect: webView.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "\(owner?.name(of: id) ?? "Extension") Options"
        window.contentView = webView
        window.isReleasedWhenClosed = false
        window.center()
        optionsWindows[id] = window
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.optionsWindows.removeValue(forKey: id) }
        }
        window.makeKeyAndOrderFront(nil)
    }

    private func id(of context: WKWebExtensionContext) -> String? {
        contexts.first { $0.value === context }?.key
    }

    /// Asks the user to allow what an extension asked for while running.
    private func confirm(_ context: WKWebExtensionContext, items: [String], completion: @escaping (Bool) -> Void) {
        let name = id(of: context).flatMap { owner?.name(of: $0) } ?? "An extension"
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Allow “\(name)” to use more of the GitHub.com pane?"
            alert.informativeText = items.sorted().joined(separator: "\n")
            alert.addButton(withTitle: "Allow")
            alert.addButton(withTitle: "Don’t Allow")
            completion(alert.runModal() == .alertFirstButtonReturn)
        }
    }

    // MARK: WKWebExtensionControllerDelegate

    func webExtensionController(_ controller: WKWebExtensionController,
                                openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        [window]
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        window
    }

    /// The pane has one page at a time, so a new tab for a GitHub page loads in the visible one, and anything
    /// else opens in the default browser.
    func webExtensionController(_ controller: WKWebExtensionController,
                                openNewTabUsing configuration: WKWebExtension.TabConfiguration,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void) {
        guard let url = configuration.url else {
            completionHandler(nil, nil)
            return
        }
        if let tab = activeTab, let session = tab.session,
           WebNavigationPolicy.isGitHubHost(url.host) || url.scheme == WebNavigationPolicy.extensionScheme {
            session.webView.load(URLRequest(url: url))
            completionHandler(tab, nil)
        } else {
            NSWorkspace.shared.open(url)
            completionHandler(nil, nil)
        }
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                openOptionsPageFor extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any Error)?) -> Void) {
        if let id = id(of: extensionContext) { openOptions(for: id) }
        completionHandler(nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                promptForPermissions permissions: Set<WKWebExtension.Permission>,
                                in tab: (any WKWebExtensionTab)?,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        confirm(extensionContext, items: permissions.map(\.rawValue)) { [weak self] allowed in
            if allowed, let self, let id = self.id(of: extensionContext) {
                self.owner?.remember(permissions: permissions.map(\.rawValue), matchPatterns: [], for: id)
            }
            completionHandler(allowed ? permissions : [], nil)
        }
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                promptForPermissionToAccess urls: Set<URL>,
                                in tab: (any WKWebExtensionTab)?,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<URL>, Date?) -> Void) {
        confirm(extensionContext, items: urls.map { $0.host ?? $0.absoluteString }) { allowed in
            completionHandler(allowed ? urls : [], nil)
        }
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
                                in tab: (any WKWebExtensionTab)?,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        confirm(extensionContext, items: matchPatterns.map(\.string)) { [weak self] allowed in
            if allowed, let self, let id = self.id(of: extensionContext) {
                self.owner?.remember(permissions: [], matchPatterns: matchPatterns.map(\.string), for: id)
            }
            completionHandler(allowed ? matchPatterns : [], nil)
        }
    }

    /// Shows the popup under the top right of the pane, where the toolbar's Extensions menu is.
    func webExtensionController(_ controller: WKWebExtensionController,
                                presentActionPopup action: WKWebExtension.Action,
                                for context: WKWebExtensionContext,
                                completionHandler: @escaping ((any Error)?) -> Void) {
        guard let popover = action.popupPopover, let anchor = activeTab?.session?.webView, anchor.window != nil else {
            completionHandler(NSError(domain: "GithubPanel.WebExtensions", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "There is no page to show the extension's popup on.",
            ]))
            return
        }
        let rect = NSRect(x: anchor.bounds.maxX - 60, y: anchor.isFlipped ? 0 : anchor.bounds.maxY, width: 1, height: 1)
        popover.show(relativeTo: rect, of: anchor, preferredEdge: anchor.isFlipped ? .maxY : .minY)
        completionHandler(nil)
    }
}

/// A pane web view, as extensions see it.
@available(macOS 15.4, *)
@MainActor
final class WebExtensionTab: NSObject, WKWebExtensionTab {
    private(set) weak var session: PullRequestWebSession?
    private weak var host: WebExtensionHost?
    private var observations: Set<AnyCancellable> = []

    init(session: PullRequestWebSession, host: WebExtensionHost) {
        self.session = session
        self.host = host
        super.init()
        session.$currentURL.dropFirst().removeDuplicates().sink { [weak self] _ in
            guard let self else { return }
            self.host?.tabChanged(self, [.URL, .title])
        }.store(in: &observations)
        session.$isLoading.dropFirst().removeDuplicates().sink { [weak self] _ in
            guard let self else { return }
            self.host?.tabChanged(self, [.loading, .title])
        }.store(in: &observations)
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        host?.window
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        host?.orderedTabs.firstIndex { $0 === self } ?? NSNotFound
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? { session?.webView }
    func title(for context: WKWebExtensionContext) -> String? { session?.webView.title }
    func url(for context: WKWebExtensionContext) -> URL? { session?.webView.url }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !(session?.webView.isLoading ?? false) }
    func isSelected(for context: WKWebExtensionContext) -> Bool { host?.activeTab === self }
    func size(for context: WKWebExtensionContext) -> CGSize { session?.webView.bounds.size ?? .zero }
    func zoomFactor(for context: WKWebExtensionContext) -> Double { Double(session?.webView.pageZoom ?? 1) }
    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { true }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        session?.webView.load(URLRequest(url: url))
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext,
                completionHandler: @escaping ((any Error)?) -> Void) {
        if fromOrigin { session?.webView.reloadFromOrigin() } else { session?.webView.reload() }
        completionHandler(nil)
    }

    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        session?.goBack()
        completionHandler(nil)
    }

    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        session?.goForward()
        completionHandler(nil)
    }
}

/// The main window, as extensions see it: its tabs are the pane's web views.
@available(macOS 15.4, *)
@MainActor
final class WebExtensionWindow: NSObject, WKWebExtensionWindow {
    private weak var host: WebExtensionHost?

    init(host: WebExtensionHost) {
        self.host = host
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { host?.orderedTabs ?? [] }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { host?.activeTab }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState { .normal }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }

    func frame(for context: WKWebExtensionContext) -> CGRect {
        appWindow?.frame ?? .null
    }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        appWindow?.screen?.frame ?? NSScreen.main?.frame ?? .null
    }

    private var appWindow: NSWindow? {
        host?.activeTab?.session?.webView.window ?? NSApp.mainWindow
    }
}
