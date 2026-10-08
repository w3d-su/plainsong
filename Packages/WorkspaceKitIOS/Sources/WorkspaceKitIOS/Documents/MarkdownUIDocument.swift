import Foundation
import UIKit

/// UIDocument file presenter. `contents(forType:)` returns only the snapshot installed for
/// this save. It never reads a live editor buffer. Presenter callbacks do not start another
/// `NSFileCoordinator`, because UIDocument is already coordinating the read or write.
final class MarkdownUIDocument: UIDocument {
    private let stateLock = NSLock()
    private var installedSnapshot: Data?
    private var loadedBytes: Data?
    private var observedError: Error?
    private var eventHandler: (@MainActor (IOSDocumentFileEvent) -> Void)?
    private var stateObserver: NSObjectProtocol?
    private var relocationObserver: NSObjectProtocol?

    override init(fileURL: URL) {
        super.init(fileURL: fileURL)
        stateObserver = NotificationCenter.default.addObserver(
            forName: UIDocument.stateChangedNotification,
            object: self,
            queue: nil
        ) { notification in
            guard let document = notification.object as? MarkdownUIDocument else { return }
            document.relayDocumentState()
        }
        relocationObserver = NotificationCenter.default.addObserver(
            forName: UIDocument.didMoveToWritableLocationNotification,
            object: self,
            queue: nil
        ) { notification in
            guard let document = notification.object as? MarkdownUIDocument else { return }
            let oldURL = notification.userInfo?[UIDocument.didMoveToWritableLocationOldURLKey] as? URL
            document.relayUnexpectedRelocation(oldURL: oldURL)
        }
    }

    deinit {
        if let stateObserver {
            NotificationCenter.default.removeObserver(stateObserver)
        }
        if let relocationObserver {
            NotificationCenter.default.removeObserver(relocationObserver)
        }
    }

    func setEventHandler(_ handler: (@MainActor (IOSDocumentFileEvent) -> Void)?) {
        stateLock.lock()
        eventHandler = handler
        stateLock.unlock()
    }

    func installSnapshot(_ data: Data) {
        stateLock.lock()
        installedSnapshot = data
        stateLock.unlock()
    }

    func clearSnapshot() {
        stateLock.lock()
        installedSnapshot = nil
        stateLock.unlock()
    }

    func loadedData() -> Data? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return loadedBytes
    }

    func takeError() -> Error? {
        stateLock.lock()
        defer { stateLock.unlock() }
        let error = observedError
        observedError = nil
        return error
    }

    override func contents(forType _: String) throws -> Any {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let installedSnapshot else {
            throw CocoaError(.fileWriteUnknown)
        }
        return installedSnapshot
    }

    override func load(fromContents contents: Any, ofType _: String?) throws {
        let data = try Self.regularFileData(from: contents)
        guard String(data: data, encoding: .utf8) != nil else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        stateLock.lock()
        loadedBytes = data
        stateLock.unlock()
    }

    override func writeContents(
        _ contents: Any,
        to url: URL,
        for saveOperation: UIDocument.SaveOperation,
        originalContentsURL: URL?
    ) throws {
        if saveOperation == .forCreating, FileManager.default.fileExists(atPath: url.path) {
            throw CocoaError(.fileWriteFileExists)
        }
        try super.writeContents(
            contents,
            to: url,
            for: saveOperation,
            originalContentsURL: originalContentsURL
        )
    }

    /// Close and file coordination must not pull live text. The store writes snapshots itself.
    override func autosave(completionHandler: ((Bool) -> Void)? = nil) {
        completionHandler?(true)
    }

    override func savePresentedItemChanges(completionHandler: @escaping (Error?) -> Void) {
        completionHandler(nil)
    }

    override func handleError(_ error: Error, userInteractionPermitted _: Bool) {
        stateLock.lock()
        observedError = error
        stateLock.unlock()
        finishedHandlingError(error, recovered: false)
    }

    override func presentedItemDidChange() {
        super.presentedItemDidChange()
        emit(.externalChange)
    }

    override func presentedItemDidGain(_ version: NSFileVersion) {
        super.presentedItemDidGain(version)
        emit(.externalChange)
    }

    override func presentedItemDidMove(to newURL: URL) {
        super.presentedItemDidMove(to: newURL)
        emit(.unexpectedRelocation(oldURL: fileURL, newURL: newURL))
    }

    override func accommodatePresentedItemDeletion(completionHandler: @escaping (Error?) -> Void) {
        super.accommodatePresentedItemDeletion { error in
            completionHandler(error)
        }
        emit(.deleted)
    }

    private func relayDocumentState() {
        let state = documentState
        if state.contains(.inConflict) {
            emit(.externalChange)
        }
        if state.contains(.editingDisabled) {
            emit(.becameReadOnly)
        }
    }

    private func relayUnexpectedRelocation(oldURL: URL?) {
        emit(.unexpectedRelocation(oldURL: oldURL ?? fileURL, newURL: fileURL))
    }

    private func emit(_ event: IOSDocumentFileEvent) {
        stateLock.lock()
        let handler = eventHandler
        stateLock.unlock()
        guard let handler else { return }
        Task { @MainActor in
            handler(event)
        }
    }

    private static func regularFileData(from contents: Any) throws -> Data {
        if let data = contents as? Data {
            return data
        }
        if let wrapper = contents as? FileWrapper {
            if let data = wrapper.regularFileContents {
                return data
            }
            throw CocoaError(.fileReadCorruptFile)
        }
        throw CocoaError(.fileReadUnsupportedScheme)
    }
}
