import Foundation

enum WebExtensionPackageError: LocalizedError, Equatable {
    case notACRXFile
    case unsupportedCRXVersion(UInt32)
    case truncatedCRXFile
    case unsupportedFile(String)
    case missingManifest
    case invalidManifest
    case unpackFailed(String)

    var errorDescription: String? {
        switch self {
        case .notACRXFile: return "The file isn't a Chrome extension (.crx) package."
        case .unsupportedCRXVersion(let version): return "CRX version \(version) isn't supported."
        case .truncatedCRXFile: return "The .crx file is incomplete."
        case .unsupportedFile(let name): return "\(name) isn't an extension folder, .zip, or .crx file."
        case .missingManifest: return "No manifest.json was found. Choose the folder that contains it."
        case .invalidManifest: return "The extension's manifest.json can't be read."
        case .unpackFailed(let message): return "The extension couldn't be unpacked: \(message)"
        }
    }
}

/// Reads the formats a Chrome extension comes in: an unpacked folder, a .zip, or a .crx, which is a .zip behind a
/// signed header.
enum WebExtensionPackage {
    /// The .zip inside a .crx. Data that is already a .zip comes back as it is.
    static func zipData(fromCRX data: Data) throws -> Data {
        let bytes = [UInt8](data)
        if bytes.starts(with: zipSignature) { return data }
        guard bytes.starts(with: Array("Cr24".utf8)) else { throw WebExtensionPackageError.notACRXFile }
        guard bytes.count >= 12 else { throw WebExtensionPackageError.truncatedCRXFile }
        let version = littleEndianUInt32(bytes, at: 4)
        let zipStart: Int
        switch version {
        case 2:
            // Magic, version, public key length, signature length, then the key and the signature.
            guard bytes.count >= 16 else { throw WebExtensionPackageError.truncatedCRXFile }
            zipStart = 16 + Int(littleEndianUInt32(bytes, at: 8)) + Int(littleEndianUInt32(bytes, at: 12))
        case 3:
            // Magic, version, header length, then the protobuf header.
            zipStart = 12 + Int(littleEndianUInt32(bytes, at: 8))
        default:
            throw WebExtensionPackageError.unsupportedCRXVersion(version)
        }
        guard zipStart < bytes.count, bytes[zipStart...].starts(with: zipSignature) else {
            throw WebExtensionPackageError.truncatedCRXFile
        }
        return Data(bytes[zipStart...])
    }

    /// The folder holding manifest.json: `directory` itself, or its only folder, as in a .zip of a folder.
    static func manifestRoot(in directory: URL, fileManager: FileManager = .default) throws -> URL {
        if fileManager.fileExists(atPath: directory.appendingPathComponent("manifest.json").path) {
            return directory
        }
        let children = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                                                           options: [.skipsHiddenFiles])
        let folders = children.filter {
            $0.lastPathComponent != "__MACOSX" && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        if folders.count == 1,
           fileManager.fileExists(atPath: folders[0].appendingPathComponent("manifest.json").path) {
            return folders[0]
        }
        throw WebExtensionPackageError.missingManifest
    }

    struct Summary: Equatable {
        var name: String
        var version: String?
    }

    /// The extension's name and version from its manifest, with a `__MSG_name__` name looked up in the default
    /// locale's messages.
    static func summary(ofExtensionAt root: URL) throws -> Summary {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("manifest.json")),
              let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawName = manifest["name"] as? String else {
            throw WebExtensionPackageError.invalidManifest
        }
        let locale = manifest["default_locale"] as? String
        let name = localized(rawName, in: root, locale: locale) ?? rawName
        return Summary(name: name, version: manifest["version"] as? String)
    }

    /// The message a `__MSG_key__` string names, or nil when it isn't one or the message is missing. Chrome matches
    /// message keys without regard to case.
    static func localized(_ string: String, in root: URL, locale: String?) -> String? {
        guard string.hasPrefix("__MSG_"), string.hasSuffix("__"), string.count > 8, let locale else { return nil }
        let key = String(string.dropFirst(6).dropLast(2)).lowercased()
        let url = root.appendingPathComponent("_locales").appendingPathComponent(locale)
            .appendingPathComponent("messages.json")
        guard let data = try? Data(contentsOf: url),
              let messages = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let entry = messages.first { $0.key.lowercased() == key }?.value as? [String: Any]
        return entry?["message"] as? String
    }

    private static let zipSignature: [UInt8] = [0x50, 0x4B, 0x03, 0x04]

    private static func littleEndianUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        guard offset + 4 <= bytes.count else { return 0 }
        return (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
    }
}
