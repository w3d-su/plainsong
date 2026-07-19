import Foundation
import MarkdownCore

struct WorkspaceMutationTextRecoveryRecord: Codable, Equatable, Identifiable {
    enum Reason: String, Codable {
        case trash
        case indeterminateMutation
    }

    let id: UUID
    let originalURL: URL
    let fileKind: FileKind
    let revision: Int
    let updatedAt: Date
    let reason: Reason

    private let sourceUTF8: Data

    var source: String {
        guard let source = String(data: sourceUTF8, encoding: .utf8) else {
            preconditionFailure("A decoded recovery record must contain valid UTF-8")
        }
        return source
    }

    init(
        id: UUID = UUID(),
        originalURL: URL,
        fileKind: FileKind,
        source: String,
        revision: Int,
        updatedAt: Date = Date(),
        reason: Reason
    ) {
        self.id = id
        self.originalURL = originalURL
        self.fileKind = fileKind
        self.revision = revision
        self.updatedAt = updatedAt
        self.reason = reason
        sourceUTF8 = Data(source.utf8)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        originalURL = try container.decode(URL.self, forKey: .originalURL)
        fileKind = try container.decode(FileKind.self, forKey: .fileKind)
        revision = try container.decode(Int.self, forKey: .revision)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        reason = try container.decode(Reason.self, forKey: .reason)
        sourceUTF8 = try container.decode(Data.self, forKey: .sourceUTF8)

        guard String(data: sourceUTF8, encoding: .utf8) != nil else {
            throw DecodingError.dataCorruptedError(
                forKey: .sourceUTF8,
                in: container,
                debugDescription: "Recovery source is not valid UTF-8"
            )
        }
    }

    func replacingOriginalURL(
        _ originalURL: URL,
        updatedAt: Date = Date()
    ) -> WorkspaceMutationTextRecoveryRecord {
        WorkspaceMutationTextRecoveryRecord(
            id: id,
            originalURL: originalURL,
            fileKind: FileKind(url: originalURL) ?? fileKind,
            source: source,
            revision: revision,
            updatedAt: updatedAt,
            reason: reason
        )
    }
}

protocol WorkspaceMutationTextRecoveryPersisting: AnyObject {
    func load() throws -> [WorkspaceMutationTextRecoveryRecord]
    func upsert(_ record: WorkspaceMutationTextRecoveryRecord) throws
    func remove(id: UUID) throws
    func quarantine(id: UUID) throws
    func quarantineAfterLoadFailure() throws
}

extension WorkspaceMutationTextRecoveryPersisting {
    func quarantineAfterLoadFailure() throws {}
}

final class WorkspaceMutationTextRecoveryStore: WorkspaceMutationTextRecoveryPersisting {
    static let applicationSupportDirectoryName = "Plainsong"
    static let recoveryDirectoryName = "WorkspaceMutationTextRecovery"

    private let directoryURL: URL
    private let directoryDurabilityBoundaryURL: URL
    private let fileManager: FileManager
    private let encoder: PropertyListEncoder
    private let decoder: PropertyListDecoder
    private var didDurablyEnsureRecoveryDirectory = false

    convenience init(fileManager: FileManager = .default) {
        let applicationSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let directoryURL = applicationSupportURL
            .appendingPathComponent(Self.applicationSupportDirectoryName, isDirectory: true)
            .appendingPathComponent(Self.recoveryDirectoryName, isDirectory: true)
        self.init(
            directoryURL: directoryURL,
            fileManager: fileManager,
            directoryDurabilityBoundaryURL: applicationSupportURL
        )
    }

    init(
        directoryURL: URL,
        fileManager: FileManager = .default,
        directoryDurabilityBoundaryURL: URL? = nil
    ) {
        self.directoryURL = directoryURL
        self.directoryDurabilityBoundaryURL =
            directoryDurabilityBoundaryURL
                ?? directoryURL.deletingLastPathComponent()
        self.fileManager = fileManager
        encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        decoder = PropertyListDecoder()
    }

    func load() throws -> [WorkspaceMutationTextRecoveryRecord] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory) else {
            return []
        }
        guard isDirectory.boolValue else {
            throw CocoaError(
                .fileReadInvalidFileName,
                userInfo: [NSFilePathErrorKey: directoryURL.path]
            )
        }

        let recordURLs = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        var records: [WorkspaceMutationTextRecoveryRecord] = []
        records.reserveCapacity(recordURLs.count)

        for recordURL in recordURLs.sorted(by: Self.fileURLSort) {
            guard recordURL.pathExtension == "plist" else { continue }
            do {
                guard let filenameID = Self.recordID(for: recordURL) else {
                    throw CocoaError(
                        .fileReadCorruptFile,
                        userInfo: [NSFilePathErrorKey: recordURL.path]
                    )
                }
                let values = try recordURL.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                )
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw CocoaError(
                        .fileReadCorruptFile,
                        userInfo: [NSFilePathErrorKey: recordURL.path]
                    )
                }
                let data = try Data(contentsOf: recordURL)
                let record = try decoder.decode(
                    WorkspaceMutationTextRecoveryRecord.self,
                    from: data
                )
                guard record.id == filenameID else {
                    throw CocoaError(
                        .fileReadCorruptFile,
                        userInfo: [NSFilePathErrorKey: recordURL.path]
                    )
                }
                records.append(record)
            } catch {
                // Preserve the malformed recovery untouched, but surface the load failure so
                // startup cannot silently fall back to an older operation bundle or Last Opened.
                throw error
            }
        }

        return records.sorted(by: Self.recordSort)
    }

    func upsert(_ record: WorkspaceMutationTextRecoveryRecord) throws {
        try ensureRecoveryDirectory()
        let data = try encoder.encode(record)
        let destination = recordURL(for: record.id)
        try WorkspaceMutationRecoveryDurableFileStore.write(
            data,
            to: destination,
            directoryURL: directoryURL
        )
    }

    func remove(id: UUID) throws {
        try WorkspaceMutationRecoveryDurableFileStore.remove(
            recordURL(for: id),
            directoryURL: directoryURL
        )
    }

    func quarantine(id: UUID) throws {
        let quarantineFilename =
            "\(Self.recordFilename(for: id))-stop-tracking-" +
            "\(UUID().uuidString.lowercased()).quarantine"
        try WorkspaceMutationRecoveryDurableFileStore.quarantineRecord(
            recordURL(for: id),
            as: quarantineFilename,
            directoryURL: directoryURL
        )
    }

    func quarantineAfterLoadFailure() throws {
        try WorkspaceMutationRecoveryDurableFileStore.quarantineRecoveryDirectory(
            directoryURL
        )
        didDurablyEnsureRecoveryDirectory = false
    }

    static func recordFilename(for id: UUID) -> String {
        "\(id.uuidString.lowercased()).plist"
    }

    private func ensureRecoveryDirectory() throws {
        try WorkspaceMutationRecoveryDurableFileStore.ensureDirectoryHierarchy(
            directoryURL,
            existingHierarchyDurabilityBoundaryURL:
            directoryDurabilityBoundaryURL,
            synchronizeExistingHierarchy:
            !didDurablyEnsureRecoveryDirectory
        )
        didDurablyEnsureRecoveryDirectory = true
    }

    private func recordURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent(Self.recordFilename(for: id), isDirectory: false)
    }

    private static func recordID(for url: URL) -> UUID? {
        UUID(uuidString: url.deletingPathExtension().lastPathComponent)
    }

    private static func fileURLSort(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.lastPathComponent.utf8.lexicographicallyPrecedes(rhs.lastPathComponent.utf8)
    }

    private static func recordSort(
        _ lhs: WorkspaceMutationTextRecoveryRecord,
        _ rhs: WorkspaceMutationTextRecoveryRecord
    ) -> Bool {
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt < rhs.updatedAt
        }
        return lhs.id.uuidString.utf8.lexicographicallyPrecedes(rhs.id.uuidString.utf8)
    }
}
