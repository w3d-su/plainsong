import Foundation
import MarkdownCore

public struct MarkdownFile: Sendable, Equatable {
    public let url: URL
    public let text: String
    public let fileKind: FileKind

    public init(url: URL, text: String, fileKind: FileKind) {
        self.url = url
        self.text = text
        self.fileKind = fileKind
    }
}

public enum MarkdownFileStoreError: LocalizedError, Equatable {
    case unsupportedExtension(URL)
    case unreadable(URL)
    case unwritable(URL)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedExtension(url):
            "\(url.lastPathComponent) is not a supported Markdown or MDX file."
        case let .unreadable(url):
            "Could not read \(url.lastPathComponent) as UTF-8 Markdown."
        case let .unwritable(url):
            "Could not save changes to \(url.lastPathComponent)."
        }
    }
}

public struct MarkdownFileStore: Sendable {
    public init() {}

    public func load(url: URL) throws -> MarkdownFile {
        let fileKind = try Self.validatedFileKind(for: url)

        do {
            let text = try SecurityScopedAccess.withAccess(to: url) {
                let data = try Data(contentsOf: url)
                guard let text = String(data: data, encoding: .utf8) else {
                    throw MarkdownFileStoreError.unreadable(url)
                }
                return text
            }
            return MarkdownFile(url: url, text: text, fileKind: fileKind)
        } catch let error as MarkdownFileStoreError {
            throw error
        } catch {
            throw MarkdownFileStoreError.unreadable(url)
        }
    }

    public func save(text: String, to url: URL) throws {
        _ = try Self.validatedFileKind(for: url)

        do {
            try SecurityScopedAccess.withAccess(to: url) {
                try Data(text.utf8).write(to: url, options: [.atomic])
            }
        } catch let error as MarkdownFileStoreError {
            throw error
        } catch {
            throw MarkdownFileStoreError.unwritable(url)
        }
    }

    private static func validatedFileKind(for url: URL) throws -> FileKind {
        guard let fileKind = FileKind(url: url) else {
            throw MarkdownFileStoreError.unsupportedExtension(url)
        }
        return fileKind
    }
}
