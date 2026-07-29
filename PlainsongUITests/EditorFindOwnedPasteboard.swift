import AppKit
import Foundation

typealias EditorFindPasteboardSnapshot =
    [[NSPasteboard.PasteboardType: Data]]

struct EditorFindPasteboardObservation {
    let beforeChangeCount: Int
    let snapshot: EditorFindPasteboardSnapshot
    let afterChangeCount: Int
}

/// Owns only the general-pasteboard state that this UI test actually writes.
///
/// The original contents are captured lazily immediately before the first paste. Restoration
/// proceeds only if both the change count and exact item bytes still match the last test-owned
/// write. External changes always win. An in-flight mutation retains retry authority only while
/// exact readback still proves that the pasteboard contains this test's nonce-marked contents.
@MainActor
final class EditorFindOwnedPasteboard {
    enum RestorationOutcome: Equatable {
        case notNeeded
        case restored
        case externalChangePreserved
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
    ) -> Bool
    typealias Observer = (NSPasteboard) throws
        -> EditorFindPasteboardObservation

    fileprivate struct ObservedState: Equatable {
        let changeCount: Int
        let snapshot: EditorFindPasteboardSnapshot
    }

    fileprivate enum Mutation {
        case installingOwned(
            original: EditorFindPasteboardSnapshot,
            previous: ObservedState,
            expected: EditorFindPasteboardSnapshot
        )
        case restoringOriginal(
            original: EditorFindPasteboardSnapshot,
            owned: ObservedState
        )
    }

    private enum OwnershipState {
        case untouched
        case owned(
            original: EditorFindPasteboardSnapshot,
            current: ObservedState
        )
        case mutationInFlight(Mutation)
        case restored
        case externalChangePreserved
    }

    private static let ownerType = NSPasteboard.PasteboardType(
        "app.plainsong.editor.ui-tests.editor-find-pasteboard-owner"
    )

    private let pasteboard: NSPasteboard
    private let ownerToken = Data(UUID().uuidString.utf8)
    private let writer: Writer
    private let observer: Observer
    private var state = OwnershipState.untouched

    init(
        pasteboard: NSPasteboard = .general,
        writer: @escaping Writer = { pasteboard, objects, expectedChangeCount in
            EditorFindOwnedPasteboard.writeObjects(
                objects,
                to: pasteboard,
                ifChangeCountIs: expectedChangeCount
            )
        },
        observer: @escaping Observer = { pasteboard in
            let before = pasteboard.changeCount
            let snapshot = try EditorFindOwnedPasteboard.exactSnapshot(
                of: pasteboard.pasteboardItems ?? []
            )
            return EditorFindPasteboardObservation(
                beforeChangeCount: before,
                snapshot: snapshot,
                afterChangeCount: pasteboard.changeCount
            )
        }
    ) {
        self.pasteboard = pasteboard
        self.writer = writer
        self.observer = observer
    }

    var hasPendingRestoration: Bool {
        switch state {
        case .owned, .mutationInFlight:
            true
        case .untouched, .restored, .externalChangePreserved:
            false
        }
    }

    func writeString(_ value: String) throws {
        if case .mutationInFlight = state {
            try resolveInFlightMutation()
            try writeString(value)
            return
        }

        let (original, previous) = try stateBeforeOwnedWrite()
        let item = NSPasteboardItem()
        item.setString(value, forType: .string)
        item.setData(ownerToken, forType: Self.ownerType)
        let expected = Self.snapshot(of: [item])
        state = .mutationInFlight(
            .installingOwned(
                original: original,
                previous: previous,
                expected: expected
            )
        )

        let didWrite = writer(
            pasteboard,
            [item],
            previous.changeCount
        )
        try finishOwnedWrite(
            original: original,
            previous: previous,
            expected: expected,
            didWrite: didWrite
        )
    }

    func restoreIfStillOwned() throws -> RestorationOutcome {
        if case .mutationInFlight = state {
            try resolveInFlightMutation()
        }

        switch state {
        case .untouched, .restored:
            return .notNeeded
        case .externalChangePreserved:
            return .externalChangePreserved
        case let .owned(original, current):
            guard try observeStableState() == current else {
                state = .externalChangePreserved
                return .externalChangePreserved
            }
            state = .mutationInFlight(
                .restoringOriginal(original: original, owned: current)
            )
            let items = Self.items(from: original)
            let didWrite = writer(
                pasteboard,
                items,
                current.changeCount
            )
            return try finishOriginalRestoration(
                original: original,
                owned: current,
                didWrite: didWrite
            )
        case .mutationInFlight:
            throw PasteboardError.changedDuringRead
        }
    }

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
    ) -> Bool {
        guard pasteboard.changeCount == expectedChangeCount else {
            return false
        }
        pasteboard.clearContents()
        return pasteboard.writeObjects(objects)
    }

    private static func exactSnapshot(
        of items: [NSPasteboardItem]
    ) throws -> EditorFindPasteboardSnapshot {
        try items.map { item in
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

private extension EditorFindOwnedPasteboard {
    func stateBeforeOwnedWrite() throws
        -> (EditorFindPasteboardSnapshot, ObservedState)
    {
        switch state {
        case .untouched, .restored:
            let observed = try observeStableState()
            return (observed.snapshot, observed)
        case let .owned(original, current):
            guard try observeStableState() == current else {
                state = .externalChangePreserved
                throw PasteboardError.externalChangeBeforeWrite
            }
            return (original, current)
        case .externalChangePreserved:
            throw PasteboardError.externalChangeBeforeWrite
        case .mutationInFlight:
            throw PasteboardError.changedDuringRead
        }
    }

    func finishOwnedWrite(
        original: EditorFindPasteboardSnapshot,
        previous: ObservedState,
        expected: EditorFindPasteboardSnapshot,
        didWrite: Bool
    ) throws {
        let observed = try observeStableState()
        if observed.snapshot == expected {
            state = .owned(original: original, current: observed)
            guard didWrite else {
                throw PasteboardError.couldNotWriteOwnedContents
            }
            return
        }

        retainOnlyProvenOwnership(
            original: original,
            previous: previous,
            observed: observed
        )
        if !didWrite {
            throw PasteboardError.couldNotWriteOwnedContents
        }
        throw PasteboardError.ownedContentsReadbackMismatch
    }

    func finishOriginalRestoration(
        original: EditorFindPasteboardSnapshot,
        owned: ObservedState,
        didWrite: Bool
    ) throws -> RestorationOutcome {
        let observed = try observeStableState()
        if observed.snapshot == original {
            state = .restored
            return .restored
        }

        if observed == owned,
           isOwnedSnapshot(observed.snapshot)
        {
            state = .owned(original: original, current: observed)
        } else {
            state = .externalChangePreserved
        }
        if !didWrite {
            throw PasteboardError.couldNotRestoreOriginalContents
        }
        throw PasteboardError.originalContentsReadbackMismatch
    }

    func resolveInFlightMutation() throws {
        guard case let .mutationInFlight(mutation) = state else {
            return
        }
        let observed = try observeStableState()
        switch mutation {
        case let .installingOwned(original, previous, expected):
            if observed.snapshot == expected {
                state = .owned(original: original, current: observed)
            } else {
                retainOnlyProvenOwnership(
                    original: original,
                    previous: previous,
                    observed: observed
                )
            }
        case let .restoringOriginal(original, owned):
            if observed.snapshot == original {
                state = .restored
            } else if observed == owned,
                      isOwnedSnapshot(observed.snapshot)
            {
                state = .owned(original: original, current: observed)
            } else {
                state = .externalChangePreserved
            }
        }
    }

    func retainOnlyProvenOwnership(
        original: EditorFindPasteboardSnapshot,
        previous: ObservedState,
        observed: ObservedState
    ) {
        if observed == previous,
           isOwnedSnapshot(observed.snapshot)
        {
            state = .owned(original: original, current: observed)
        } else if observed == previous {
            state = .restored
        } else {
            state = .externalChangePreserved
        }
    }

    func isOwnedSnapshot(
        _ snapshot: EditorFindPasteboardSnapshot
    ) -> Bool {
        snapshot.contains { item in
            item[Self.ownerType] == ownerToken
        }
    }

    func observeStableState() throws -> ObservedState {
        let observation = try observer(pasteboard)
        guard observation.beforeChangeCount == observation.afterChangeCount else {
            throw PasteboardError.changedDuringRead
        }
        return ObservedState(
            changeCount: observation.afterChangeCount,
            snapshot: observation.snapshot
        )
    }

    static func items(
        from snapshot: EditorFindPasteboardSnapshot
    ) -> [NSPasteboardWriting] {
        snapshot.map { values in
            let item = NSPasteboardItem()
            for (type, data) in values {
                item.setData(data, forType: type)
            }
            return item
        }
    }
}
