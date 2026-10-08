import Foundation
import MarkdownCore

public actor IOSDocumentRecoveryStore: IOSRecoveryPersisting {
    public let directory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(directory: URL) {
        self.directory = directory
    }

    public func persist(_ record: IOSRecoveryRecord) async throws -> IOSRecoveryReceipt {
        guard record.formatVersion == 1 else {
            throw IOSDocumentFailure.recoveryFailed
        }
        let data: Data
        do {
            data = try encoder.encode(record)
        } catch {
            throw IOSDocumentFailure.recoveryFailed
        }
        let url = fileURL(recordID: record.recordID)
        do {
            try IOSDurableFile.writeAtomically(data, to: url)
        } catch {
            throw IOSDocumentFailure.recoveryFailed
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw IOSDocumentFailure.recoveryFailed
        }
        return IOSRecoveryReceipt(
            operationID: record.operationID,
            revision: IOSDocumentRevision(
                documentID: IOSDocumentIdentity(rawValue: record.documentID),
                version: record.revisionVersion
            ),
            recordID: record.recordID
        )
    }

    public func list() async -> IOSRecoveryList {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            if FileManager.default.fileExists(atPath: directory.path) {
                return IOSRecoveryList(records: [], corruptNames: [directory.lastPathComponent])
            }
            return IOSRecoveryList(records: [], corruptNames: [])
        }
        var records: [IOSRecoveryRecord] = []
        var corrupt: [String] = []
        for name in names where name.hasSuffix(".recovery.json") {
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url), let record = try? decoder.decode(
                IOSRecoveryRecord.self,
                from: data
            ),
                record.formatVersion == 1,
                fileURL(recordID: record.recordID).lastPathComponent == name
            else {
                corrupt.append(name)
                continue
            }
            records.append(record)
        }
        return IOSRecoveryList(records: records, corruptNames: corrupt)
    }

    public func load(_ recordID: UUID) async throws -> IOSRecoveryRecord {
        let url = fileURL(recordID: recordID)
        guard let data = try? Data(contentsOf: url) else {
            throw IOSRecoveryDiscardError.missing
        }
        guard let record = try? decoder.decode(IOSRecoveryRecord.self, from: data), record.formatVersion == 1 else {
            throw IOSRecoveryDiscardError.corrupt
        }
        return record
    }

    public func discard(
        recordID: UUID,
        persistedText: String,
        liveText: String,
        liveVersion: Int
    ) async throws {
        let record = try await load(recordID)
        guard ExactSourceText.matches(persistedText, record.source) else {
            throw IOSRecoveryDiscardError.contentNotConfirmed
        }
        let liveIsNewer = liveVersion > record.revisionVersion
        if liveIsNewer, !ExactSourceText.matches(liveText, record.source) {
            throw IOSRecoveryDiscardError.newerLocalRevision
        }
        do {
            try FileManager.default.removeItem(at: fileURL(recordID: recordID))
        } catch {
            throw IOSDocumentFailure.recoveryFailed
        }
    }

    private func fileURL(recordID: UUID) -> URL {
        directory.appendingPathComponent("\(recordID.uuidString.lowercased()).recovery.json")
    }
}
