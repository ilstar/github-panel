import XCTest

final class AppIconAssetTests: XCTestCase {
    func testAppIconCatalogReferencesExpectedMacPNGs() throws {
        let iconSet = repositoryRoot()
            .appendingPathComponent("GithubPanel/Assets.xcassets/AppIcon.appiconset")
        let contentsURL = iconSet.appendingPathComponent("Contents.json")
        let catalog = try JSONDecoder().decode(AppIconCatalog.self, from: Data(contentsOf: contentsURL))
        let expected: [String: (filename: String, pixels: PNGSize)] = [
            "16x16@1x": ("icon_16x16.png", PNGSize(width: 16, height: 16)),
            "16x16@2x": ("icon_16x16@2x.png", PNGSize(width: 32, height: 32)),
            "32x32@1x": ("icon_32x32.png", PNGSize(width: 32, height: 32)),
            "32x32@2x": ("icon_32x32@2x.png", PNGSize(width: 64, height: 64)),
            "128x128@1x": ("icon_128x128.png", PNGSize(width: 128, height: 128)),
            "128x128@2x": ("icon_128x128@2x.png", PNGSize(width: 256, height: 256)),
            "256x256@1x": ("icon_256x256.png", PNGSize(width: 256, height: 256)),
            "256x256@2x": ("icon_256x256@2x.png", PNGSize(width: 512, height: 512)),
            "512x512@1x": ("icon_512x512.png", PNGSize(width: 512, height: 512)),
            "512x512@2x": ("icon_512x512@2x.png", PNGSize(width: 1024, height: 1024)),
        ]

        var seen = Set<String>()
        for image in catalog.images {
            let key = "\(image.size)@\(image.scale)"
            let requirement = try XCTUnwrap(expected[key])
            XCTAssertEqual(image.idiom, "mac")
            XCTAssertEqual(image.filename, requirement.filename)
            XCTAssertEqual(try pngSize(of: iconSet.appendingPathComponent(image.filename)), requirement.pixels)
            seen.insert(key)
        }

        XCTAssertEqual(seen, Set(expected.keys))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func pngSize(of url: URL) throws -> PNGSize {
        let data = try Data(contentsOf: url)
        XCTAssertGreaterThanOrEqual(data.count, 24)
        XCTAssertEqual(Array(data.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])

        let width = data[16..<20].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let height = data[20..<24].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return PNGSize(width: Int(width), height: Int(height))
    }
}

private struct AppIconCatalog: Decodable {
    let images: [AppIconImage]
}

private struct AppIconImage: Decodable {
    let filename: String
    let idiom: String
    let size: String
    let scale: String
}

private struct PNGSize: Equatable {
    let width: Int
    let height: Int
}
