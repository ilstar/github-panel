import Foundation
import WebKit

/// Searches a page for text. `WKWebView` is the real one; tests use a fake.
@MainActor
protocol PageTextFinder: AnyObject {
    /// Selects and scrolls to the next match, wrapping at the ends, and returns whether there is one.
    /// `fromSelectionStart` searches from the start of the current match instead of after it, so a longer
    /// query that still matches the same text stays on it.
    func findText(_ text: String, backwards: Bool, fromSelectionStart: Bool) async -> Bool
    /// Hands the keyboard back to the page.
    func focusPage()
}

extension WKWebView: PageTextFinder {
    func findText(_ text: String, backwards: Bool, fromSelectionStart: Bool) async -> Bool {
        if fromSelectionStart {
            _ = try? await evaluateJavaScript(
                "(function () { var s = getSelection(); if (s && s.rangeCount) s.collapseToStart(); })()")
        }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.caseSensitive = false
        configuration.wraps = true
        return await withCheckedContinuation { continuation in
            find(text, configuration: configuration) { result in
                continuation.resume(returning: result.matchFound)
            }
        }
    }

    func focusPage() {
        window?.makeFirstResponder(self)
    }
}

/// The GitHub pane's find bar: what is typed in it, and whether the page has it.
@MainActor
final class PageFind: ObservableObject {
    enum Result: Equatable {
        /// Nothing searched yet, or the query is empty.
        case none
        case found
        case notFound
    }

    @Published private(set) var isVisible = false
    @Published var query = "" {
        didSet {
            if query != oldValue { search(backwards: false, fromSelectionStart: true) }
        }
    }
    @Published private(set) var result: Result = .none
    /// Goes up each time the find field should take focus, such as ⌘F while the bar is already open.
    @Published private(set) var focusRequest = 0

    /// The page being searched: the web view in the pane. A new page has not been searched yet.
    weak var finder: PageTextFinder? {
        didSet {
            if finder !== oldValue { result = .none }
        }
    }

    /// The latest search, so an older one that finishes late doesn't overwrite its result.
    private var searchID = 0

    func show() {
        isVisible = true
        focusRequest += 1
    }

    /// Closes the bar and hands the keyboard back to the page. The last match stays selected.
    func hide() {
        guard isVisible else { return }
        isVisible = false
        result = .none
        finder?.focusPage()
    }

    /// The next match, or the bar when there is nothing to search for yet.
    func findNext() {
        find(backwards: false)
    }

    func findPrevious() {
        find(backwards: true)
    }

    private func find(backwards: Bool) {
        if query.isEmpty {
            show()
        } else {
            search(backwards: backwards, fromSelectionStart: false)
        }
    }

    private func search(backwards: Bool, fromSelectionStart: Bool) {
        searchID += 1
        guard let finder, !query.isEmpty else {
            result = .none
            return
        }
        let id = searchID
        let text = query
        Task {
            let found = await finder.findText(text, backwards: backwards, fromSelectionStart: fromSelectionStart)
            guard id == self.searchID else { return }
            self.result = found ? .found : .notFound
        }
    }
}
