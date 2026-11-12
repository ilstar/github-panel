import AppKit
import SwiftUI

/// Opt-in, local-only trace for selection bugs that depend on a particular macOS/SwiftUI version.
/// Launch with --debug-pr-selection. PR IDs become session-local numbers; no titles, URLs or tokens are written.
@MainActor
final class PRSelectionDiagnostics {
    static let shared = PRSelectionDiagnostics(enabled: ProcessInfo.processInfo.arguments.contains("--debug-pr-selection"))

    private(set) var logURL: URL?
    var isEnabled: Bool { handle != nil }
    private var handle: FileHandle?
    private var rowIDs: [String: Int] = [:]
    private var bytesWritten = 0
    private let byteLimit: Int
    private let formatter = ISO8601DateFormatter()

    init(enabled: Bool, directory: URL? = nil, byteLimit: Int = 4 * 1024 * 1024) {
        self.byteLimit = byteLimit
        guard enabled else { return }
        formatter.timeZone = .current
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/GithubPanel/Selection", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("selection-\(UUID().uuidString).jsonl")
            try Data().write(to: url, options: .withoutOverwriting)
            handle = try FileHandle(forWritingTo: url)
            logURL = url
            record("session-start", fields: [
                "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                "appBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
                "reduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ])
            NSLog("PR selection diagnostics: %@", url.path)
        } catch {
            NSLog("Could not start PR selection diagnostics: %@", error.localizedDescription)
        }
    }

    func selection(_ event: String, window: UUID, selectedID: String?, previousID: String? = nil,
                   visibleIDs: [String], grouped: Bool) {
        guard isEnabled else { return }
        record(event, window: window, fields: [
            "selected": alias(selectedID), "previous": alias(previousID),
            "visible": visibleIDs.map { alias($0) },
            "duplicateCount": visibleIDs.count - Set(visibleIDs).count,
            "grouped": grouped
        ])
    }

    func row(_ event: String, window: UUID, rowID: String, instance: UUID,
             selected: Bool, hovering: Bool) {
        guard isEnabled else { return }
        record(event, window: window, fields: ["row": alias(rowID), "instance": instance.uuidString,
                                              "selected": selected, "hovering": hovering])
    }

    private func alias(_ id: String?) -> Int {
        guard let id else { return 0 }
        if let existing = rowIDs[id] { return existing }
        let value = rowIDs.count + 1
        rowIDs[id] = value
        return value
    }

    private func record(_ event: String, window: UUID? = nil, fields: [String: Any]) {
        guard let handle else { return }
        var entry = fields
        entry["event"] = event
        entry["time"] = formatter.string(from: Date())
        entry["window"] = window?.uuidString
        guard var data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        data.append(0x0a)
        do {
            let footer = Data("{\"event\":\"size-limit-reached\"}\n".utf8)
            if bytesWritten + data.count + footer.count > byteLimit {
                if bytesWritten + footer.count <= byteLimit { try handle.write(contentsOf: footer) }
                stop()
                return
            }
            try handle.write(contentsOf: data)
            bytesWritten += data.count
        } catch {
            NSLog("Could not write PR selection diagnostics: %@", error.localizedDescription)
            stop()
        }
    }

    func stop() {
        try? handle?.close()
        handle = nil
    }

    deinit { try? handle?.close() }
}

/// Logs the values that reach the native view update boundary, without observing or changing selection.
struct PRSelectionDiagnosticProbe: NSViewRepresentable {
    let windowID: UUID
    let rowID: String
    let isSelected: Bool
    let isHovering: Bool

    struct Snapshot: Equatable {
        let windowID: UUID
        let rowID: String
        let isSelected: Bool
        let isHovering: Bool
    }

    func makeNSView(context: Context) -> ProbeView { ProbeView() }

    func updateNSView(_ view: ProbeView, context: Context) {
        let snapshot = Snapshot(windowID: windowID, rowID: rowID, isSelected: isSelected, isHovering: isHovering)
        guard view.snapshot != snapshot else { return }
        view.snapshot = snapshot
        view.record("row-update")
    }

    static func dismantleNSView(_ view: ProbeView, coordinator: ()) { view.record("row-dismantle") }

    final class ProbeView: NSView {
        let instanceID = UUID()
        var snapshot: Snapshot?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            record(window == nil ? "row-detach" : "row-attach")
        }

        func record(_ event: String) {
            guard let snapshot else { return }
            PRSelectionDiagnostics.shared.row(event, window: snapshot.windowID, rowID: snapshot.rowID,
                                              instance: instanceID, selected: snapshot.isSelected,
                                              hovering: snapshot.isHovering)
        }
    }
}
