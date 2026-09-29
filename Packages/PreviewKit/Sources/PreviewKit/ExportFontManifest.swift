import Foundation

enum ExportFontManifest {
    static func woff2FileNames(in previewDirectory: URL?) -> Set<String> {
        guard let previewDirectory else {
            return []
        }
        let url = previewDirectory.appendingPathComponent("font-manifest.json")
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(Document.self, from: data),
              manifest.format == "woff2"
        else {
            return []
        }
        return Set(manifest.files.filter(isBundledWoff2Name))
    }

    static func dataURI(fileName: String, fontDirectory: URL, manifest: Set<String>) -> String? {
        guard manifest.contains(fileName), isBundledWoff2Name(fileName) else {
            return nil
        }
        let directory = fontDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let fileURL = directory.appendingPathComponent(fileName, isDirectory: false)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let directoryPath = normalized(directory.path(percentEncoded: false))
        let filePath = fileURL.path(percentEncoded: false)
        guard fileURL.lastPathComponent == fileName,
              filePath.hasPrefix("\(directoryPath)/")
        else {
            return nil
        }
        guard let data = try? Data(contentsOf: fileURL),
              data.count <= maximumFontBytes,
              !data.isEmpty
        else {
            return nil
        }
        return "data:font/woff2;base64,\(data.base64EncodedString())"
    }

    static func bundledFileName(from source: String) -> String? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(".."), !trimmed.contains("\\") else {
            return nil
        }
        let path = trimmed.split(separator: "?", maxSplits: 1).first.map(String.init) ?? trimmed
        let name = (path as NSString).lastPathComponent
        guard isBundledWoff2Name(name) || isDroppedFontName(name) else {
            return nil
        }
        return name
    }

    private static let maximumFontBytes = 1_048_576

    private struct Document: Decodable {
        let format: String
        let files: [String]
    }

    private static func isBundledWoff2Name(_ name: String) -> Bool {
        guard name.hasSuffix(".woff2"), name.count > ".woff2".count, name.count < 200 else {
            return false
        }
        return name.allSatisfy(isSafeCharacter)
    }

    private static func isDroppedFontName(_ name: String) -> Bool {
        name.hasSuffix(".woff") || name.hasSuffix(".ttf") || name.hasSuffix(".otf")
    }

    private static func isSafeCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || "-_.".contains(character))
    }

    private static func normalized(_ path: String) -> String {
        guard path != "/" else {
            return path
        }
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
