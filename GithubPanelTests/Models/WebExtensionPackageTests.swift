import XCTest
@testable import GithubPanel

final class WebExtensionPackageTests: XCTestCase {
    private let zip = Data([0x50, 0x4B, 0x03, 0x04, 0x0A, 0x0B, 0x0C])

    func testCRX3ReturnsTheZipAfterTheHeader() throws {
        XCTAssertEqual(try WebExtensionPackage.zipData(fromCRX: WebExtensionFixtures.crx3(wrapping: zip)), zip)
    }

    func testCRX2ReturnsTheZipAfterTheKeyAndSignature() throws {
        XCTAssertEqual(try WebExtensionPackage.zipData(fromCRX: WebExtensionFixtures.crx2(wrapping: zip)), zip)
    }

    func testAZipComesBackAsItIs() throws {
        XCTAssertEqual(try WebExtensionPackage.zipData(fromCRX: zip), zip)
    }

    func testOtherFilesAreRejected() {
        XCTAssertThrowsError(try WebExtensionPackage.zipData(fromCRX: Data("hello world!".utf8))) {
            XCTAssertEqual($0 as? WebExtensionPackageError, .notACRXFile)
        }
    }

    func testUnknownCRXVersionsAreRejected() {
        var data = WebExtensionFixtures.crx3(wrapping: zip)
        data[4] = 9
        XCTAssertThrowsError(try WebExtensionPackage.zipData(fromCRX: data)) {
            XCTAssertEqual($0 as? WebExtensionPackageError, .unsupportedCRXVersion(9))
        }
    }

    func testAHeaderLongerThanTheFileIsRejected() {
        let data = WebExtensionFixtures.crx3(wrapping: zip).prefix(16)
        XCTAssertThrowsError(try WebExtensionPackage.zipData(fromCRX: Data(data))) {
            XCTAssertEqual($0 as? WebExtensionPackageError, .truncatedCRXFile)
        }
    }

    func testManifestRootIsTheFolderOrItsOnlySubfolder() throws {
        let directory = try WebExtensionFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let flat = try WebExtensionFixtures.writeExtension(in: directory.appendingPathComponent("flat"))
        XCTAssertEqual(try WebExtensionPackage.manifestRoot(in: flat).standardizedFileURL, flat.standardizedFileURL)

        let wrapper = directory.appendingPathComponent("wrapper")
        let nested = try WebExtensionFixtures.writeExtension(in: wrapper.appendingPathComponent("my-extension"))
        try FileManager.default.createDirectory(at: wrapper.appendingPathComponent("__MACOSX"),
                                                withIntermediateDirectories: true)
        XCTAssertEqual(try WebExtensionPackage.manifestRoot(in: wrapper).standardizedFileURL, nested.standardizedFileURL)
    }

    func testAFolderWithoutAManifestIsRejected() throws {
        let directory = try WebExtensionFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertThrowsError(try WebExtensionPackage.manifestRoot(in: directory)) {
            XCTAssertEqual($0 as? WebExtensionPackageError, .missingManifest)
        }
    }

    func testSummaryReadsTheNameAndVersion() throws {
        let directory = try WebExtensionFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try WebExtensionFixtures.writeExtension(in: directory, name: "Refined", version: "26.1")
        XCTAssertEqual(try WebExtensionPackage.summary(ofExtensionAt: directory),
                       .init(name: "Refined", version: "26.1"))
    }

    func testSummaryLooksUpALocalizedNameWithoutRegardToCase() throws {
        let directory = try WebExtensionFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try WebExtensionFixtures.writeExtension(in: directory, localizedName: "Localized Name")
        XCTAssertEqual(try WebExtensionPackage.summary(ofExtensionAt: directory).name, "Localized Name")
    }

    func testSummaryRejectsAManifestWithoutAName() throws {
        let directory = try WebExtensionFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("{\"version\": \"1\"}".utf8).write(to: directory.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try WebExtensionPackage.summary(ofExtensionAt: directory)) {
            XCTAssertEqual($0 as? WebExtensionPackageError, .invalidManifest)
        }
    }
}
