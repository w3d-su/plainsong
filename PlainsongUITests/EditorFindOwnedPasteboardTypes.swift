import AppKit
import Foundation

extension EditorFindOwnedPasteboard {
    enum RestorationOutcome: Equatable {
        case notNeeded
        case restored
        case externalChangePreserved
    }

    enum WriteResult: Equatable {
        case boundaryMismatch
        case attempted(didWrite: Bool, ownedChangeCount: Int)

        var didWrite: Bool {
            if case let .attempted(didWrite, _) = self {
                return didWrite
            }
            return false
        }
    }

    enum PasteboardError: Error, CustomStringConvertible {
        case changedDuringRead
        case externalChangeBeforeWrite
        case couldNotCaptureExactContents
        case couldNotWriteOwnedContents
        case ownedContentsReadbackMismatch
        case couldNotRestoreOriginalContents
        case originalContentsReadbackMismatch

        var description: String {
            switch self {
            case .changedDuringRead:
                "The pasteboard changed while its ownership state was being read"
            case .externalChangeBeforeWrite:
                "The pasteboard changed externally before the next test-owned write"
            case .couldNotCaptureExactContents:
                "The pasteboard contained a type whose exact bytes could not be captured"
            case .couldNotWriteOwnedContents:
                "The pasteboard rejected the test-owned contents"
            case .ownedContentsReadbackMismatch:
                "The test-owned pasteboard contents failed exact readback"
            case .couldNotRestoreOriginalContents:
                "The pasteboard rejected its original contents"
            case .originalContentsReadbackMismatch:
                "The restored pasteboard contents failed exact readback"
            }
        }
    }

    typealias Writer = (
        NSPasteboard,
        [NSPasteboardWriting],
        Int
    ) -> WriteResult
    typealias Observer = (NSPasteboard) throws
        -> EditorFindPasteboardObservation

    static func snapshot(
        of items: [NSPasteboardItem]
    ) -> EditorFindPasteboardSnapshot {
        items.map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
    }

    /// Rechecks ownership at the last public NSPasteboard boundary before mutation.
    ///
    /// AppKit does not expose an atomic compare-and-swap pasteboard API, so an external
    /// process can still race between this read and `clearContents()`. Exact post-write
    /// readback prevents this helper from retaining ownership of such an external result.
    static func writeObjects(
        _ objects: [NSPasteboardWriting],
        to pasteboard: NSPasteboard,
        ifChangeCountIs expectedChangeCount: Int
    ) -> WriteResult {
        guard pasteboard.changeCount == expectedChangeCount else {
            return .boundaryMismatch
        }
        let ownedChangeCount = pasteboard.clearContents()
        if objects.isEmpty {
            // Clearing is the complete requested mutation when the captured
            // original pasteboard was empty; AppKit reports writeObjects([])
            // as false even though the helper-owned empty generation is valid.
            return .attempted(
                didWrite: true,
                ownedChangeCount: ownedChangeCount
            )
        }
        return .attempted(
            didWrite: pasteboard.writeObjects(objects),
            ownedChangeCount: ownedChangeCount
        )
    }

    static func exactSnapshot(
        of items: [NSPasteboardItem]?,
        advertisedTypes: [NSPasteboard.PasteboardType]?
    ) throws -> EditorFindPasteboardSnapshot {
        guard let items else {
            guard advertisedTypes?.isEmpty != false else {
                throw PasteboardError.couldNotCaptureExactContents
            }
            // AppKit represents an empty pasteboard as nil items and nil types. The API
            // exposes no further signal that can distinguish that state from a total
            // retrieval failure which also reports neither items nor types.
            return []
        }
        return try items.map { item in
            var values: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else {
                    throw PasteboardError.couldNotCaptureExactContents
                }
                values[type] = data
            }
            return values
        }
    }
}
