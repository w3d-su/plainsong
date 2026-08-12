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
/// write. A distinct external generation observed at an ownership boundary wins. AppKit has no
/// atomic compare-and-swap, so a final check-to-clear race remains. An in-flight mutation retains
/// retry authority only while exact readback proves its nonce-marked contents, its prior authorized
/// state, or the exact empty generation produced by its own clear.
@MainActor
final class EditorFindOwnedPasteboard {
    fileprivate struct ObservedState: Equatable {
        let changeCount: Int
        let snapshot: EditorFindPasteboardSnapshot
    }

    fileprivate enum Mutation {
        case installingOwned(
            original: EditorFindPasteboardSnapshot,
            previous: ObservedState,
            previousWasOwned: Bool,
            expected: EditorFindPasteboardSnapshot,
            writeResult: WriteResult?
        )
        case restoringOriginal(
            original: EditorFindPasteboardSnapshot,
            owned: ObservedState,
            writeResult: WriteResult?
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
                of: pasteboard.pasteboardItems,
                advertisedTypes: pasteboard.types
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

        let (original, previous, previousWasOwned) =
            try stateBeforeOwnedWrite()
        let item = NSPasteboardItem()
        guard item.setString(value, forType: .string),
              item.setData(ownerToken, forType: Self.ownerType)
        else {
            throw PasteboardError.couldNotWriteOwnedContents
        }
        let expected = Self.snapshot(of: [item])
        state = .mutationInFlight(
            .installingOwned(
                original: original,
                previous: previous,
                previousWasOwned: previousWasOwned,
                expected: expected,
                writeResult: nil
            )
        )

        let writeResult = writer(
            pasteboard,
            [item],
            previous.changeCount
        )
        state = .mutationInFlight(
            .installingOwned(
                original: original,
                previous: previous,
                previousWasOwned: previousWasOwned,
                expected: expected,
                writeResult: writeResult
            )
        )
        try finishOwnedWrite(
            original: original,
            previous: previous,
            previousWasOwned: previousWasOwned,
            expected: expected,
            writeResult: writeResult
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
                .restoringOriginal(
                    original: original,
                    owned: current,
                    writeResult: nil
                )
            )
            let items = try Self.items(from: original)
            let writeResult = writer(
                pasteboard,
                items,
                current.changeCount
            )
            state = .mutationInFlight(
                .restoringOriginal(
                    original: original,
                    owned: current,
                    writeResult: writeResult
                )
            )
            return try finishOriginalRestoration(
                original: original,
                owned: current,
                writeResult: writeResult
            )
        case .mutationInFlight:
            throw PasteboardError.changedDuringRead
        }
    }
}

private extension EditorFindOwnedPasteboard {
    func stateBeforeOwnedWrite() throws
        -> (EditorFindPasteboardSnapshot, ObservedState, Bool)
    {
        switch state {
        case .untouched, .restored:
            let observed = try observeStableState()
            return (observed.snapshot, observed, false)
        case let .owned(original, current):
            guard try observeStableState() == current else {
                state = .externalChangePreserved
                throw PasteboardError.externalChangeBeforeWrite
            }
            return (original, current, true)
        case .externalChangePreserved:
            throw PasteboardError.externalChangeBeforeWrite
        case .mutationInFlight:
            throw PasteboardError.changedDuringRead
        }
    }

    func finishOwnedWrite(
        original: EditorFindPasteboardSnapshot,
        previous: ObservedState,
        previousWasOwned: Bool,
        expected: EditorFindPasteboardSnapshot,
        writeResult: WriteResult
    ) throws {
        let observed = try observeStableState()
        if writeResultOwns(
            observed,
            expectedSnapshot: expected,
            writeResult: writeResult
        ) {
            state = .owned(original: original, current: observed)
            guard writeResult.didWrite else {
                throw PasteboardError.couldNotWriteOwnedContents
            }
            return
        }

        retainOnlyProvenOwnership(
            original: original,
            previous: previous,
            previousWasOwned: previousWasOwned,
            observed: observed,
            writeResult: writeResult
        )
        if !writeResult.didWrite {
            throw PasteboardError.couldNotWriteOwnedContents
        }
        throw PasteboardError.ownedContentsReadbackMismatch
    }

    func finishOriginalRestoration(
        original: EditorFindPasteboardSnapshot,
        owned: ObservedState,
        writeResult: WriteResult
    ) throws -> RestorationOutcome {
        let observed = try observeStableState()
        if writeResultOwns(
            observed,
            expectedSnapshot: original,
            writeResult: writeResult
        ) {
            state = .restored
            return .restored
        }

        if observed == owned {
            state = .owned(original: original, current: observed)
        } else if isOwnedFailedClear(
            observed,
            from: writeResult
        ) {
            state = .owned(original: original, current: observed)
        } else {
            state = .externalChangePreserved
        }
        if !writeResult.didWrite {
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
        case let .installingOwned(
            original,
            previous,
            previousWasOwned,
            expected,
            writeResult
        ):
            if let writeResult,
               writeResultOwns(
                   observed,
                   expectedSnapshot: expected,
                   writeResult: writeResult
               )
            {
                state = .owned(original: original, current: observed)
            } else {
                retainOnlyProvenOwnership(
                    original: original,
                    previous: previous,
                    previousWasOwned: previousWasOwned,
                    observed: observed,
                    writeResult: writeResult
                )
            }
        case let .restoringOriginal(original, owned, writeResult):
            if let writeResult,
               writeResultOwns(
                   observed,
                   expectedSnapshot: original,
                   writeResult: writeResult
               )
            {
                state = .restored
            } else if observed == owned {
                state = .owned(original: original, current: observed)
            } else if let writeResult,
                      isOwnedFailedClear(observed, from: writeResult)
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
        previousWasOwned: Bool,
        observed: ObservedState,
        writeResult: WriteResult?
    ) {
        if observed == previous, previousWasOwned {
            state = .owned(original: original, current: previous)
        } else if observed == previous {
            state = .restored
        } else if let writeResult,
                  isOwnedFailedClear(observed, from: writeResult)
        {
            state = .owned(original: original, current: observed)
        } else {
            state = .externalChangePreserved
        }
    }

    func isOwnedFailedClear(
        _ observed: ObservedState,
        from writeResult: WriteResult
    ) -> Bool {
        guard case let .attempted(_, ownedChangeCount) = writeResult else {
            return false
        }
        return observed.changeCount == ownedChangeCount
            && observed.snapshot.isEmpty
    }

    func writeResultOwns(
        _ observed: ObservedState,
        expectedSnapshot: EditorFindPasteboardSnapshot,
        writeResult: WriteResult
    ) -> Bool {
        guard case let .attempted(_, ownedChangeCount) = writeResult else {
            return false
        }
        return observed.changeCount == ownedChangeCount
            && observed.snapshot == expectedSnapshot
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
    ) throws -> [NSPasteboardWriting] {
        try snapshot.map { values in
            let item = NSPasteboardItem()
            for (type, data) in values {
                guard item.setData(data, forType: type) else {
                    throw PasteboardError.couldNotRestoreOriginalContents
                }
            }
            return item
        }
    }
}
