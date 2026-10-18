import XCTest
@testable import GithubPanel

final class WebExtensionLibraryTests: XCTestCase {
    private var directory: URL!
    private var root: URL { directory.appendingPathComponent("Library") }

    override func setUpWithError() throws {
        directory = try WebExtensionFixtures.temporaryDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testInstallingAFolderCopiesItIntoTheLibrary() throws {
        let source = try WebExtensionFixtures.writeExtension(in: directory.appendingPathComponent("source"))
        let library = WebExtensionLibrary(root: root)

        let installed = try library.install(from: source)

        XCTAssertEqual(installed.name, "Sample")
        XCTAssertEqual(installed.version, "1.2.3")
        XCTAssertTrue(installed.isEnabled)
        XCTAssertEqual(installed.id, installed.id.lowercased())
        XCTAssertEqual(library.extensions, [installed])
        let copied = library.directory(for: installed.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.appendingPathComponent("content.js").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "the original folder stays")
    }

    func testInstallingAZipUnpacksTheFolderInside() throws {
        let source = try WebExtensionFixtures.writeExtension(in: directory.appendingPathComponent("zipped"))
        let archive = try WebExtensionFixtures.zip(source, to: directory.appendingPathComponent("ext.zip"))
        let library = WebExtensionLibrary(root: root)

        let installed = try library.install(from: archive)

        let manifest = library.directory(for: installed.id).appendingPathComponent("manifest.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.path))
    }

    func testInstallingACRXUnpacksItsZip() throws {
        let source = try WebExtensionFixtures.writeExtension(in: directory.appendingPathComponent("packed"),
                                                             name: "Packed")
        let archive = try WebExtensionFixtures.zip(source, to: directory.appendingPathComponent("ext.zip"))
        let crx = directory.appendingPathComponent("ext.crx")
        try WebExtensionFixtures.crx3(wrapping: Data(contentsOf: archive)).write(to: crx)
        let library = WebExtensionLibrary(root: root)

        XCTAssertEqual(try library.install(from: crx).name, "Packed")
    }

    func testOtherFilesAreRejectedWithoutChangingTheLibrary() throws {
        let file = directory.appendingPathComponent("notes.txt")
        try Data("hi".utf8).write(to: file)
        let library = WebExtensionLibrary(root: root)

        XCTAssertThrowsError(try library.install(from: file)) {
            XCTAssertEqual($0 as? WebExtensionPackageError, .unsupportedFile("notes.txt"))
        }
        XCTAssertTrue(library.extensions.isEmpty)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        XCTAssertFalse(leftovers.contains { $0.hasPrefix(".staging") })
    }

    func testTheListAndChangesSurviveAReload() throws {
        let source = try WebExtensionFixtures.writeExtension(in: directory.appendingPathComponent("source"))
        let library = WebExtensionLibrary(root: root)
        var installed = try library.install(from: source)
        installed.isEnabled = false
        installed.grantedPermissions = ["tabs"]
        try library.update(installed)

        XCTAssertEqual(WebExtensionLibrary(root: root).extensions, [installed])
    }

    func testRemovingDeletesTheExtensionAndItsFolder() throws {
        let source = try WebExtensionFixtures.writeExtension(in: directory.appendingPathComponent("source"))
        let library = WebExtensionLibrary(root: root)
        let installed = try library.install(from: source)

        try library.remove(id: installed.id)

        XCTAssertTrue(library.extensions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.directory(for: installed.id).path))
        XCTAssertTrue(WebExtensionLibrary(root: root).extensions.isEmpty)
    }

    func testEntriesWhoseFolderIsGoneAreDropped() throws {
        let source = try WebExtensionFixtures.writeExtension(in: directory.appendingPathComponent("source"))
        let library = WebExtensionLibrary(root: root)
        let installed = try library.install(from: source)
        try FileManager.default.removeItem(at: library.directory(for: installed.id))

        XCTAssertTrue(WebExtensionLibrary(root: root).extensions.isEmpty)
    }
}
