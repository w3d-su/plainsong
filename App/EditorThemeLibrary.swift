import Foundation
import MarkdownCore

struct EditorThemeCatalog: Equatable {
    var themes: [CustomThemeDocument]
    var invalidIdentifiers: Set<String>

    func theme(identifier: String) -> CustomThemeDocument? {
        themes.first { $0.id == identifier }
    }
}

enum EditorThemeStoreError: Equatable, Error, LocalizedError {
    case unreadable
    case invalid(CustomThemeValidationFailure)
    case notFound(String)
    case failedToStore

    var errorDescription: String? {
        switch self {
        case .unreadable:
            "The theme file could not be read."
        case let .invalid(failure):
            EditorThemeValidationMessage.text(for: failure)
        case let .notFound(identifier):
            "No imported theme with the id \"\(identifier)\" was found."
        case .failedToStore:
            "The theme could not be saved."
        }
    }
}

enum EditorThemeImportResult: Equatable {
    case imported(CustomThemeDocument)
    case replacementDeclined(id: String)
}

enum EditorThemeValidationMessage {
    static func text(for failure: CustomThemeValidationFailure) -> String {
        switch failure {
        case .exceedsMaximumSize:
            "Theme files must be 64 KiB or smaller."
        case .invalidUTF8:
            "Theme files must be UTF-8 text."
        case .invalidJSON:
            "The theme file is not a JSON object of schema version 1."
        case let .unknownField(field):
            "The theme file has an unknown field \"\(field)\". Schema version 1 rejects the whole file."
        case let .missingField(field):
            "The theme file is missing \"\(field)\"."
        case let .unsupportedSchemaVersion(version):
            "Theme schema version \(version) is not supported. This version of Plainsong reads version 1."
        case .identifier:
            "Theme ids must be 1-64 characters from a-z, 0-9, and hyphen."
        case let .reservedIdentifier(identifier):
            "\"\(identifier)\" is a built-in theme id."
        case .name:
            "Theme names must be 1-64 characters."
        case let .color(field):
            "\"\(field)\" must be a #RRGGBB or #RRGGBBAA color."
        }
    }
}

struct EditorThemeLibrary {
    let directory: URL
    private let fileManager: FileManager

    init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    static func production(fileManager: FileManager = .default) -> EditorThemeLibrary {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let directory = applicationSupport
            .appendingPathComponent("Plainsong", isDirectory: true)
            .appendingPathComponent("Themes", isDirectory: true)
        return EditorThemeLibrary(directory: directory, fileManager: fileManager)
    }

    func loadCatalog() -> EditorThemeCatalog {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return EditorThemeCatalog(themes: [], invalidIdentifiers: [])
        }

        var themes: [CustomThemeDocument] = []
        var invalid: Set<String> = []
        for url in files where url.pathExtension == "json" {
            let identifier = url.deletingPathExtension().lastPathComponent
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isSymbolicLink != true,
                  values.isRegularFile == true,
                  let data = try? Data(contentsOf: url),
                  case let .success(document) = CustomThemeValidation.validate(data),
                  document.id == identifier
            else {
                invalid.insert(identifier)
                continue
            }
            themes.append(document)
        }
        return EditorThemeCatalog(themes: themes, invalidIdentifiers: invalid)
    }

    func importTheme(
        data: Data,
        replacingExisting: (CustomThemeDocument) -> Bool
    ) throws -> EditorThemeImportResult {
        let document: CustomThemeDocument
        switch CustomThemeValidation.validate(data) {
        case let .success(validated):
            document = validated
        case let .failure(failure):
            throw EditorThemeStoreError.invalid(failure)
        }
        guard let destination = themeFileURL(identifier: document.id) else {
            throw EditorThemeStoreError.invalid(.identifier)
        }
        if fileManager.fileExists(atPath: destination.path) {
            guard replacingExisting(document) else {
                return .replacementDeclined(id: document.id)
            }
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
        } catch {
            throw EditorThemeStoreError.failedToStore
        }
        return .imported(document)
    }

    func existingFileURL(identifier: String) -> URL? {
        guard let url = themeFileURL(identifier: identifier),
              fileManager.fileExists(atPath: url.path)
        else {
            return nil
        }
        return url
    }

    @discardableResult
    func moveToTrash(identifier: String) throws -> URL {
        guard let url = existingFileURL(identifier: identifier) else {
            throw EditorThemeStoreError.notFound(identifier)
        }
        var trashed: NSURL?
        do {
            try fileManager.trashItem(at: url, resultingItemURL: &trashed)
        } catch {
            throw EditorThemeStoreError.failedToStore
        }
        guard let trashed else {
            throw EditorThemeStoreError.failedToStore
        }
        return trashed as URL
    }

    private func themeFileURL(identifier: String) -> URL? {
        guard CustomThemeValidation.isIdentifier(identifier),
              !identifier.contains("/")
        else {
            return nil
        }
        let url = directory.appendingPathComponent("\(identifier).json", isDirectory: false)
        let directoryPath = directory.standardizedFileURL.path
        let filePath = url.standardizedFileURL.deletingLastPathComponent().path
        guard filePath == directoryPath else { return nil }
        return url
    }
}
