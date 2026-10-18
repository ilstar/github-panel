import Foundation

/// Small extensions written to a temporary folder, as an unpacked folder, a .zip, or a .crx.
enum WebExtensionFixtures {
    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WebExtensionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// An unpacked Manifest V3 extension with a content script for github.com and a toolbar button.
    @discardableResult
    static func writeExtension(in directory: URL, name: String = "Sample", version: String = "1.2.3",
                               localizedName: String? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var manifest: [String: Any] = [
            "manifest_version": 3,
            "name": localizedName == nil ? name : "__MSG_extName__",
            "version": version,
            "action": ["default_title": name],
            "permissions": ["storage"],
            "content_scripts": [["matches": ["https://github.com/*"], "js": ["content.js"]]],
        ]
        if let localizedName {
            manifest["default_locale"] = "en"
            let locale = directory.appendingPathComponent("_locales/en", isDirectory: true)
            try FileManager.default.createDirectory(at: locale, withIntermediateDirectories: true)
            let messages = ["extname": ["message": localizedName]]
            try JSONSerialization.data(withJSONObject: messages).write(to: locale.appendingPathComponent("messages.json"))
        }
        try JSONSerialization.data(withJSONObject: manifest).write(to: directory.appendingPathComponent("manifest.json"))
        try Data("document.documentElement.dataset.sample = '1';".utf8)
            .write(to: directory.appendingPathComponent("content.js"))
        return directory
    }

    /// A .zip of `folder`, holding the folder itself as Chrome's "Pack" and most downloads do.
    static func zip(_ folder: URL, to destination: URL) throws -> URL {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", folder.path, destination.path]
        try process.run()
        process.waitUntilExit()
        return destination
    }

    /// A CRX3 file: the magic, version 3, a header length, a header, then the .zip.
    static func crx3(wrapping zip: Data, headerLength: Int = 7) -> Data {
        var data = Data("Cr24".utf8)
        data.append(littleEndian(3))
        data.append(littleEndian(UInt32(headerLength)))
        data.append(Data(repeating: 0xAB, count: headerLength))
        data.append(zip)
        return data
    }

    /// A CRX2 file: the magic, version 2, key and signature lengths, the key and signature, then the .zip.
    static func crx2(wrapping zip: Data, keyLength: Int = 5, signatureLength: Int = 3) -> Data {
        var data = Data("Cr24".utf8)
        data.append(littleEndian(2))
        data.append(littleEndian(UInt32(keyLength)))
        data.append(littleEndian(UInt32(signatureLength)))
        data.append(Data(repeating: 0x01, count: keyLength + signatureLength))
        data.append(zip)
        return data
    }

    private static func littleEndian(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}
