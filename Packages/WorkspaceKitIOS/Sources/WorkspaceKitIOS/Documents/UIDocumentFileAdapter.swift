import Foundation
import UIKit

/// Production file port. UIDocument remains the document writer. Save-copy and external
/// reads stay on the coordinated-access seam and are not nested in these callbacks.
@MainActor
final class UIDocumentFileAdapter: IOSDocumentFilePort {
    let fileURL: URL
    private var document: MarkdownUIDocument?
    private var handler: (@MainActor (IOSDocumentFileEvent) -> Void)?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func setHandler(_ handler: (@MainActor (IOSDocumentFileEvent) -> Void)?) {
        self.handler = handler
        document?.setEventHandler(handler)
    }

    func open() async throws -> IOSDocumentFileOpenResult {
        let document = prepareDocument()
        let success = await open(document)
        guard success, let data = document.loadedData() else {
            throw map(document.takeError(), fallback: .unavailable)
        }
        try rejectPlaceholder(at: document.fileURL)
        let canWrite = try writePermission(at: document.fileURL)
        return IOSDocumentFileOpenResult(data: data, canWrite: canWrite)
    }

    func create(snapshot: Data) async throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            throw IOSDocumentFailure.access(.alreadyExists)
        }
        let document = prepareDocument()
        document.installSnapshot(snapshot)
        let success = await save(document, snapshotIsNew: true)
        document.clearSnapshot()
        guard success else {
            throw map(document.takeError(), fallback: .saveFailed)
        }
    }

    func save(
        snapshot: Data,
        operationID: UUID,
        completion: @escaping @MainActor (IOSDocumentFileWriteDisposition) -> Void
    ) {
        let document = prepareDocument()
        document.installSnapshot(snapshot)
        document.save(to: document.fileURL, for: .forOverwriting) { success in
            let error = document.takeError()
            document.clearSnapshot()
            Task { @MainActor in
                if success {
                    completion(.stored)
                } else if self.isIndeterminate(error) {
                    completion(.indeterminate)
                } else {
                    completion(.failed)
                }
            }
        }
        _ = operationID
    }

    func close() async throws {
        guard let document else { return }
        let success = await close(document)
        if !success {
            throw map(document.takeError(), fallback: .closeFailed)
        }
    }

    private func prepareDocument() -> MarkdownUIDocument {
        if let document {
            return document
        }
        let document = MarkdownUIDocument(fileURL: fileURL)
        document.setEventHandler(handler)
        self.document = document
        return document
    }

    private func open(_ document: MarkdownUIDocument) async -> Bool {
        await withCheckedContinuation { continuation in
            document.open { success in
                continuation.resume(returning: success)
            }
        }
    }

    private func save(_ document: MarkdownUIDocument, snapshotIsNew: Bool) async -> Bool {
        let operation: UIDocument.SaveOperation = snapshotIsNew ? .forCreating : .forOverwriting
        return await withCheckedContinuation { continuation in
            document.save(to: document.fileURL, for: operation) { success in
                continuation.resume(returning: success)
            }
        }
    }

    private func close(_ document: MarkdownUIDocument) async -> Bool {
        await withCheckedContinuation { continuation in
            document.close { success in
                continuation.resume(returning: success)
            }
        }
    }

    private func rejectPlaceholder(at url: URL) throws {
        let keys: Set<URLResourceKey> = [
            .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemIsDownloadingKey,
            .ubiquitousItemIsUploadedKey,
        ]
        let values = try? url.resourceValues(forKeys: keys)
        if values?.ubiquitousItemIsDownloading == true {
            throw IOSDocumentFailure.access(.downloading)
        }
        if let status = values?.ubiquitousItemDownloadingStatus, status != .current, status != .downloaded {
            throw IOSDocumentFailure.access(.offline)
        }
    }

    private func writePermission(at url: URL) throws -> Bool {
        let values = try? url.resourceValues(forKeys: [.isWritableKey])
        return values?.isWritable ?? true
    }

    private func map(_ error: Error?, fallback: IOSDocumentFailure) -> IOSDocumentFailure {
        guard let error else { return fallback }
        let cocoa = error as NSError
        if cocoa.domain == NSCocoaErrorDomain, cocoa.code == CocoaError.fileWriteFileExists.rawValue {
            return .access(.alreadyExists)
        }
        if cocoa.domain == NSCocoaErrorDomain, cocoa.code == CocoaError.fileReadNoPermission.rawValue {
            return .access(.permissionDenied)
        }
        if cocoa.domain == NSCocoaErrorDomain, cocoa.code == CocoaError.fileReadNoSuchFile.rawValue {
            return .access(.notFound)
        }
        if cocoa.domain == NSCocoaErrorDomain,
           cocoa.code == CocoaError.fileReadInapplicableStringEncoding.rawValue
        {
            return .access(.unsupportedType)
        }
        return fallback
    }

    private func isIndeterminate(_ error: Error?) -> Bool {
        guard let error else { return false }
        let cocoa = error as NSError
        return cocoa.domain == NSPOSIXErrorDomain && cocoa.code == Int(EINPROGRESS)
    }
}
