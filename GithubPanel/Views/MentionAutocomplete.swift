import SwiftUI
import AppKit

/// Finds GitHub users for what was typed after an "@".
typealias MentionSearch = (String) async throws -> [MentionCandidate]

private struct MentionSearchKey: EnvironmentKey {
    static let defaultValue: MentionSearch? = nil
}

extension EnvironmentValues {
    /// Finds users for the @mention menu in text boxes. Nil turns the menu off.
    var mentionSearch: MentionSearch? {
        get { self[MentionSearchKey.self] }
        set { self[MentionSearchKey.self] = newValue }
    }
}

extension View {
    /// Shows GitHub's @mention menu at the cursor while "@name" is typed in this `TextEditor`.
    /// Up and Down pick a user, Return or Tab mentions them, and Escape closes the menu.
    /// Apply it to the `TextEditor` itself, so the menu can find the text view under it.
    func mentionAutocomplete() -> some View {
        modifier(MentionAutocompleteModifier())
    }
}

private struct MentionAutocompleteModifier: ViewModifier {
    @Environment(\.mentionSearch) private var search

    func body(content: Content) -> some View {
        content.background {
            if let search {
                MentionAutocompleteAnchor(search: search)
            }
        }
    }
}

/// An empty view behind the `TextEditor`. SwiftUI does not hand out the editor's `NSTextView`, so the controller
/// listens to every text view's changes and keeps the ones in this view's frame.
private struct MentionAutocompleteAnchor: NSViewRepresentable {
    let search: MentionSearch

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView()
        context.coordinator.anchor = view
        context.coordinator.start()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.search = search
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: MentionAutocompleteController) {
        coordinator.stop()
    }

    func makeCoordinator() -> MentionAutocompleteController {
        MentionAutocompleteController(search: search)
    }

    private final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Tracks the "@name" at the cursor of one text view, searches for it, and shows the matches in a panel
/// under the cursor that never takes focus from the text view.
final class MentionAutocompleteController {
    var search: MentionSearch
    weak var anchor: NSView?
    private(set) weak var textView: NSTextView?

    private(set) var query: MentionQuery?
    private(set) var candidates: [MentionCandidate] = []
    private(set) var selection = 0
    /// Where the "@" was when Escape closed the menu, so it stays closed while that mention is typed.
    private var dismissedLocation: Int?
    private var searchTask: Task<Void, Never>?
    /// Results by lowercased query, so deleting a letter shows the earlier matches right away.
    private var cache: [String: [MentionCandidate]] = [:]
    private var observers: [NSObjectProtocol] = []
    private var keyMonitor: Any?
    private var panel: MentionPanel?

    /// How long typing has to pause before searching.
    static let searchDelay: UInt64 = 200_000_000

    init(search: @escaping MentionSearch) {
        self.search = search
    }

    /// True while the menu is on screen with users in it.
    var isShowingSuggestions: Bool {
        query != nil && !candidates.isEmpty && panel?.isVisible == true
    }

    func start() {
        let center = NotificationCenter.default
        for name in [NSText.didChangeNotification, NSTextView.didChangeSelectionNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self, let textView = note.object as? NSTextView, self.owns(textView) else { return }
                self.textView = textView
                self.refresh()
            })
        }
        observers.append(center.addObserver(forName: NSText.didEndEditingNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, note.object as? NSTextView === self.textView else { return }
            self.hide()
        })
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, note.object as? NSWindow === self.textView?.window else { return }
            self.hide()
        })
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.textView?.window,
                  self.handle(keyCode: event.keyCode, modifiers: event.modifierFlags)
            else { return event }
            return nil
        }
    }

    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
        hide()
        panel?.close()
        panel = nil
    }

    /// Handles a key press while the menu is open. Returns true when the key was used up.
    func handle(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard isShowingSuggestions, let textView, textView.window?.firstResponder === textView else { return false }
        let modifiers = modifiers.intersection([.command, .option, .control, .shift])
        switch (keyCode, modifiers) {
        case (125, []), (45, .control): // down arrow, ⌃N
            select(selection + 1)
        case (126, []), (35, .control): // up arrow, ⌃P
            select(selection - 1)
        case (36, []), (76, []), (48, []): // return, enter, tab
            accept(selection)
        case (53, []): // escape
            dismissedLocation = query?.range.location
            hide()
        default:
            return false
        }
        return true
    }

    /// Replaces the "@name" being typed with the chosen user's login.
    func accept(_ index: Int) {
        guard let textView, let query, candidates.indices.contains(index) else { return }
        let completion = query.completion(for: candidates[index].login, in: textView.string)
        hide()
        // Typing it in, rather than setting the string, keeps undo working and updates the editor's binding.
        textView.insertText(completion.replacement, replacementRange: query.range)
        textView.setSelectedRange(NSRange(location: completion.caret, length: 0))
    }

    private func select(_ index: Int) {
        guard !candidates.isEmpty else { return }
        // Wraps around, like GitHub's menu.
        selection = (index + candidates.count) % candidates.count
        updatePanel()
    }

    /// A text view belongs to this editor when its middle sits inside the anchor, which has the editor's frame.
    private func owns(_ textView: NSTextView) -> Bool {
        guard let anchor, let window = anchor.window, textView.window === window,
              textView.isEditable, !textView.isFieldEditor else { return false }
        let editor = textView.enclosingScrollView ?? textView
        let editorFrame = editor.convert(editor.bounds, to: nil)
        return anchor.convert(anchor.bounds, to: nil).contains(CGPoint(x: editorFrame.midX, y: editorFrame.midY))
    }

    private func refresh() {
        guard let textView, textView.window?.firstResponder === textView else { return hide() }
        let caret = textView.selectedRange()
        guard caret.length == 0, let active = MentionQuery.active(in: textView.string, caret: caret.location) else {
            dismissedLocation = nil
            return hide()
        }
        guard active.range.location != dismissedLocation else { return hide() }

        let isNewSearch = query?.text != active.text
        query = active
        if isNewSearch {
            startSearch(active.text)
        } else {
            updatePanel()
        }
    }

    private func startSearch(_ text: String) {
        searchTask?.cancel()
        if let cached = cache[text.lowercased()] {
            show(cached)
            return
        }
        let search = self.search
        searchTask = Task { @MainActor [weak self] in
            // An "@" alone lists the repository's people at once; anything after it waits for typing to pause.
            if !text.isEmpty {
                try? await Task.sleep(nanoseconds: Self.searchDelay)
            }
            guard !Task.isCancelled else { return }
            // A failed search shows no menu rather than getting in the way of typing.
            guard let results = try? await search(text), !Task.isCancelled, let self else { return }
            self.cache[text.lowercased()] = results
            self.show(results)
        }
    }

    private func show(_ results: [MentionCandidate]) {
        guard query != nil else { return }
        candidates = results
        selection = 0
        updatePanel()
    }

    private func hide() {
        searchTask?.cancel()
        searchTask = nil
        query = nil
        candidates = []
        selection = 0
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
    }

    private func updatePanel() {
        guard let textView, let window = textView.window, let query, !candidates.isEmpty else {
            if let panel {
                panel.parent?.removeChildWindow(panel)
                panel.orderOut(nil)
            }
            return
        }
        let panel = self.panel ?? MentionPanel()
        self.panel = panel
        panel.controller = self
        panel.show(MentionSuggestionList(candidates: candidates, selection: selection,
                                         onHover: { [weak self] index in self?.select(index) },
                                         onChoose: { [weak self] index in self?.accept(index) }))

        // Under the "@", or above it when there is no room below.
        let caret = textView.firstRect(forCharacterRange: NSRange(location: query.range.location, length: 0), actualRange: nil)
        let size = panel.frame.size
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? .infinite
        var origin = CGPoint(x: caret.minX - 10, y: caret.minY - 4 - size.height)
        if origin.y < screen.minY {
            origin.y = caret.maxY + 4
        }
        origin.x = min(max(origin.x, screen.minX), screen.maxX - size.width)
        panel.setFrameOrigin(origin)
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }
}

/// The @mention menu's window. It never becomes key, so typing stays in the text view.
final class MentionPanel: NSPanel {
    weak var controller: MentionAutocompleteController?
    private let hostingView = FirstMouseHostingView(rootView: MentionSuggestionList(candidates: [], selection: 0,
                                                                                    onHover: { _ in }, onChoose: { _ in }))

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isReleasedWhenClosed = false
        hidesOnDeactivate = true
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        contentView = hostingView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    fileprivate func show(_ list: MentionSuggestionList) {
        hostingView.rootView = list
        setContentSize(hostingView.fittingSize)
    }

    /// The suggested logins in order, for tests.
    var logins: [String] { hostingView.rootView.candidates.map(\.login) }
}

/// Clicks on a row choose it right away, even though the panel is never the key window.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// GitHub's @mention menu: each user's avatar, login and name, with the chosen one highlighted.
struct MentionSuggestionList: View {
    let candidates: [MentionCandidate]
    let selection: Int
    let onHover: (Int) -> Void
    let onChoose: (Int) -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                row(candidate, isSelected: index == selection)
                    .contentShape(Rectangle())
                    .onHover { if $0 { onHover(index) } }
                    .onTapGesture { onChoose(index) }
            }
        }
        .padding(4)
        .frame(width: 280)
        .background(shape.fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(shape.strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1))
        .clipShape(shape)
    }

    private func row(_ candidate: MentionCandidate, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            AvatarView(login: candidate.login, size: 20)
            Text(candidate.login)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            if let name = candidate.name, !name.isEmpty {
                Text(name)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(isSelected ? Color.white : .primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(isSelected ? Color.accentColor : .clear))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
