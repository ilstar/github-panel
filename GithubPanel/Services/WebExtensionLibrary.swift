import Foundation

/// An extension the user added for the GitHub.com pane.
struct InstalledWebExtension: Codable, Equatable, Identifiable {
    /// A lowercase UUID, also the extension's folder name and its stable identity in WebKit, so its storage
    /// survives relaunches.
    let id: String
    var name: String
    var version: String?
    var isEnabled = true
    /// Optional permissions and sites the user allowed when the extension asked for them.
    var grantedPermissions: [String] = []
    var grantedMatchPatterns: [String] = []
}

/// Keeps the added extensions on disk: each unpacked in a folder named by its id, with `extensions.json` listing
/// them in the order they were added.
final class WebExtensionLibrary {
    let root: URL
    private(set) var extensions: [InstalledWebExtension] = []
    private let fileManager: FileManager

    init(root: URL, fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
        if let data = try? Data(contentsOf: indexURL),
           let saved = try? JSONDecoder().decode([InstalledWebExtension].self, from: data) {
            extensions = saved.filter { fileManager.fileExists(atPath: directory(for: $0.id).path) }
        }
    }

    /// Application Support, or a throwaway folder under XCTest so tests never see the extensions you use.
    static func makeDefault() -> WebExtensionLibrary {
        let base: URL
        if ProcessInfo.processInfo.isRunningTests {
            base = FileManager.default.temporaryDirectory.appendingPathComponent("GithubPanelTests-\(UUID().uuidString)")
        } else {
            base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(Bundle.main.bundleIdentifier ?? "GithubPanel")
        }
        return WebExtensionLibrary(root: base.appendingPathComponent("Extensions"))
    }

    func directory(for id: String) -> URL {
        root.appendingPathComponent(id, isDirectory: true)
    }

    /// Copies or unpacks the extension at `source`, a folder, .zip, or .crx, into the library.
    @discardableResult
    func install(from source: URL) throws -> InstalledWebExtension {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        try unpack(source, into: staging)
        let manifestRoot = try WebExtensionPackage.manifestRoot(in: staging, fileManager: fileManager)
        let summary = try WebExtensionPackage.summary(ofExtensionAt: manifestRoot)
        let id = UUID().uuidString.lowercased()
        try fileManager.moveItem(at: manifestRoot, to: directory(for: id))
        let installed = InstalledWebExtension(id: id, name: summary.name, version: summary.version)
        extensions.append(installed)
        try save()
        return installed
    }

    func remove(id: String) throws {
        extensions.removeAll { $0.id == id }
        try save()
        try? fileManager.removeItem(at: directory(for: id))
    }

    func update(_ installed: InstalledWebExtension) throws {
        guard let index = extensions.firstIndex(where: { $0.id == installed.id }) else { return }
        extensions[index] = installed
        try save()
    }

    private var indexURL: URL { root.appendingPathComponent("extensions.json") }

    private func save() throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(extensions).write(to: indexURL, options: .atomic)
    }

    private func unpack(_ source: URL, into staging: URL) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            throw WebExtensionPackageError.unsupportedFile(source.lastPathComponent)
        }
        if isDirectory.boolValue {
            try fileManager.copyItem(at: source, to: staging)
            return
        }
        switch source.pathExtension.lowercased() {
        case "zip":
            try unzip(source, into: staging)
        case "crx":
            let zip = try WebExtensionPackage.zipData(fromCRX: Data(contentsOf: source))
            let zipURL = root.appendingPathComponent(".package-\(UUID().uuidString).zip")
            defer { try? fileManager.removeItem(at: zipURL) }
            try zip.write(to: zipURL)
            try unzip(zipURL, into: staging)
        default:
            throw WebExtensionPackageError.unsupportedFile(source.lastPathComponent)
        }
    }

    private func unzip(_ archive: URL, into destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, destination.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw WebExtensionPackageError.unpackFailed(message?.isEmpty == false ? message! : "ditto failed")
        }
    }
}
