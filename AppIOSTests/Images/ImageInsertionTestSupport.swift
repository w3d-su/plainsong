import EditorKitIOS
import Foundation
import MarkdownCore
@testable import PlainsongIOS
import WorkspaceCore
import WorkspaceKitIOS
import XCTest

final class InsertionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func record(_ event: String) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

final class AsyncSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var signaled = false

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if signaled {
                lock.unlock()
                continuation.resume()
            } else {
                continuations.append(continuation)
                lock.unlock()
            }
        }
    }

    func signal() {
        lock.lock()
        signaled = true
        let pending = continuations
        continuations.removeAll()
        lock.unlock()
        pending.forEach { $0.resume() }
    }
}

struct RejectingTranscoder: IOSImageRasterTranscoding {
    func pngData(fromHEIC _: Data) -> Data? {
        nil
    }
}

final class RecordingTranscoder: IOSImageRasterTranscoding, @unchecked Sendable {
    private let lock = NSLock()
    private let png: Data
    private var ranOnMain = false

    init(png: Data) {
        self.png = png
    }

    var observedMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ranOnMain
    }

    func pngData(fromHEIC _: Data) -> Data? {
        lock.lock()
        ranOnMain = Thread.isMainThread
        lock.unlock()
        return png
    }
}

enum ImageBytes {
    static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    static func png(count: Int) -> Data {
        precondition(count >= pngSignature.count)
        var data = Data(count: count)
        data.replaceSubrange(0 ..< pngSignature.count, with: pngSignature)
        return data
    }

    static let png = png(count: 32)
    static let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
    static let gif = Data("GIF89a".utf8)
    static let gif87 = Data("GIF87a".utf8)
    static let webp: Data = {
        var data = Data("RIFF".utf8)
        data.append(contentsOf: [0x10, 0x00, 0x00, 0x00])
        data.append(contentsOf: "WEBP".utf8)
        data.append(contentsOf: [0, 0, 0, 0])
        return data
    }()

    static func heic(brand: String = "heic") -> Data {
        var data = Data(count: 24)
        data[3] = 24
        data.replaceSubrange(4 ..< 8, with: Data("ftyp".utf8))
        data.replaceSubrange(8 ..< 12, with: Data(brand.utf8))
        return data
    }

    static let svg = Data("<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>".utf8)
    static let executable = Data([0x4D, 0x5A, 0x90, 0x00])
    static let limit = Int(MarkdownImageAssetPolicy.maximumFileSizeBytes)
}

@MainActor
final class ImageEditorFake: IOSSourceEditorControlling {
    struct Snap: Equatable {
        var text: String
        var selection: NSRange
        var version: Int
        var selectionGeneration: UInt64
    }

    var bindingID = UUID()
    var identity = IOSDocumentIdentity(rawValue: UUID())
    var version: Int
    var text: String
    var selection: NSRange
    var selectionGeneration: UInt64
    var accessGeneration: UInt64
    var hasMarkedText = false
    var canWrite = true
    var isFocused = true
    var returnNilSnapshot = false
    var beforeApply: (() -> Void)?
    var nextRefusal: IOSEditRefusal?
    let probe: InsertionProbe
    private(set) var submitted: [IOSAuthorizedEdit] = []
    private(set) var undoInvocations = 0
    private(set) var redoInvocations = 0
    private var undoStack: [Snap] = []
    private var redoStack: [Snap] = []

    var revision: IOSDocumentRevision {
        IOSDocumentRevision(documentID: identity, version: version)
    }

    init(
        probe: InsertionProbe,
        text: String,
        selection: NSRange,
        version: Int = 3,
        selectionGeneration: UInt64 = 11,
        accessGeneration: UInt64 = 8
    ) {
        self.probe = probe
        self.text = text
        self.selection = selection
        self.version = version
        self.selectionGeneration = selectionGeneration
        self.accessGeneration = accessGeneration
    }

    func captureSnapshot() -> IOSSourceEditorSnapshot? {
        if returnNilSnapshot {
            return nil
        }
        let storage = text as NSString
        return IOSSourceEditorSnapshot(
            bindingID: bindingID,
            revision: revision,
            document: DocumentSnapshot(
                text: text,
                version: version,
                fileKind: .markdown,
                fileURL: nil,
                isDirty: false,
                statistics: TextStatistics(text: text)
            ),
            selection: selection,
            visibleRange: NSRange(location: 0, length: storage.length),
            selectionGeneration: selectionGeneration,
            accessGeneration: accessGeneration,
            hasMarkedText: hasMarkedText,
            canWrite: canWrite,
            isFocused: isFocused
        )
    }

    func apply(_ edit: IOSAuthorizedEdit) -> IOSEditOutcome {
        probe.record("apply")
        submitted.append(edit)
        if let hook = beforeApply {
            beforeApply = nil
            hook()
        }
        if let nextRefusal {
            self.nextRefusal = nil
            return .refused(nextRefusal)
        }
        if let refusal = refusal(for: edit) {
            return .refused(refusal)
        }
        guard let updated = replaced(text, range: edit.result.replacementRange, with: edit.result.replacementString),
              fits(edit.result.newSelection, length: (updated as NSString).length)
        else {
            return .refused(.invalidRange)
        }
        undoStack.append(Snap(
            text: text,
            selection: selection,
            version: version,
            selectionGeneration: selectionGeneration
        ))
        redoStack.removeAll()
        text = updated
        selection = edit.result.newSelection
        version += 1
        selectionGeneration += 1
        return .applied(revision)
    }

    func reveal(_: NSRange, expected _: IOSDocumentRevision) -> Bool {
        false
    }

    func undo() {
        undoInvocations += 1
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(currentSnap())
        restore(previous)
    }

    func redo() {
        redoInvocations += 1
        guard let next = redoStack.popLast() else { return }
        undoStack.append(currentSnap())
        restore(next)
    }

    private func currentSnap() -> Snap {
        Snap(text: text, selection: selection, version: version, selectionGeneration: selectionGeneration)
    }

    private func restore(_ snap: Snap) {
        text = snap.text
        selection = snap.selection
        version = snap.version
        selectionGeneration = snap.selectionGeneration
    }

    private func refusal(for edit: IOSAuthorizedEdit) -> IOSEditRefusal? {
        if edit.bindingID != bindingID {
            return .bindingChanged
        }
        if edit.baseRevision.documentID != identity {
            return .documentChanged
        }
        if edit.baseRevision.version != version {
            return .sourceChanged
        }
        if edit.selectionGeneration != selectionGeneration {
            return .selectionChanged
        }
        if edit.accessGeneration != accessGeneration {
            return .accessChanged
        }
        if hasMarkedText {
            return .markedText
        }
        if !canWrite {
            return .readOnly
        }
        if !isFocused {
            return .notFocused
        }
        return nil
    }

    private func replaced(_ source: String, range: NSRange, with replacement: String) -> String? {
        let storage = source as NSString
        guard fits(range, length: storage.length) else { return nil }
        return storage.replacingCharacters(in: range, with: replacement)
    }

    private func fits(_ range: NSRange, length: Int) -> Bool {
        guard range.location >= 0, range.length >= 0 else { return false }
        let (end, overflow) = range.location.addingReportingOverflow(range.length)
        return !overflow && end <= length
    }
}
