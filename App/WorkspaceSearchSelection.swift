import Foundation

// MARK: - Keyboard selection (pure, no AppKit/SwiftUI)

/// Focus surface for workspace search keyboard routing (WS3C PR C).
enum WorkspaceSearchFocusSurface: Equatable {
    case queryField
    case results
}

/// Navigation actions for the results list. Movement does not wrap.
enum WorkspaceSearchSelectionAction: Equatable {
    case selectFirst
    case selectLast
    case moveUp
    case moveDown
    case clear
}

#if DEBUG
    /// Debug-only observability for the hosted real-event keyboard smoke.
    ///
    /// The smoke drives **real `NSEvent`s** (`window.sendEvent`) through the field editor,
    /// the SwiftUI results focus surface, and the backing table rows; this probe only lets
    /// XCTest observe view-local selection/focus state — it never injects commands.
    @MainActor
    enum WorkspaceSearchKeyboardSmokeProbe {
        static var selectedRowID: WorkspaceSearchResultRowID?
        static var isResultsFocused = false
        static var reducerSequence: UInt64 = 0
        static var lastReducerAction: WorkspaceSearchSelectionAction?
        static var isResultsToQueryHandoffPending = false
        /// Bumped whenever selection or results-focus claims change (for `waitUntil`).
        static var epoch: UInt64 = 0

        static func reset() {
            selectedRowID = nil
            isResultsFocused = false
            reducerSequence = 0
            lastReducerAction = nil
            isResultsToQueryHandoffPending = false
            epoch = 0
        }

        static func publish(selection: WorkspaceSearchResultRowID?, resultsFocused: Bool) {
            selectedRowID = selection
            isResultsFocused = resultsFocused
            epoch &+= 1
        }

        static func recordReducer(_ action: WorkspaceSearchSelectionAction) {
            reducerSequence &+= 1
            lastReducerAction = action
            epoch &+= 1
        }

        static func publishHandoffPending(_ isPending: Bool) {
            isResultsToQueryHandoffPending = isPending
            epoch &+= 1
        }
    }
#endif

/// Pure selection reducer for ordered search-result rows.
///
/// Order is the presentation order already established by the App event path
/// (path-ordered sections, then source-range order within each file). Navigation never cycles.
enum WorkspaceSearchSelectionNavigation {
    /// Flattens section rows into a single ordered identity list.
    static func orderedRowIDs(
        in presentation: WorkspaceSearchResultsPresentation
    ) -> [WorkspaceSearchResultRowID] {
        presentation.sections.flatMap { $0.rows.map(\.id) }
    }

    /// Returns the next selection for `action`. Stale IDs (missing from `orderedIDs` or
    /// mismatched `queryGeneration`) are treated as no selection before applying the action.
    static func reduce(
        selection: WorkspaceSearchResultRowID?,
        action: WorkspaceSearchSelectionAction,
        orderedIDs: [WorkspaceSearchResultRowID],
        queryGeneration: UInt64
    ) -> WorkspaceSearchResultRowID? {
        let validSelection = resolvedSelection(
            selection,
            orderedIDs: orderedIDs,
            queryGeneration: queryGeneration
        )

        switch action {
        case .clear:
            return nil

        case .selectFirst:
            return orderedIDs.first

        case .selectLast:
            return orderedIDs.last

        case .moveDown:
            guard !orderedIDs.isEmpty else { return nil }
            guard let current = validSelection,
                  let index = orderedIDs.firstIndex(of: current)
            else {
                return orderedIDs.first
            }
            let next = orderedIDs.index(after: index)
            return next < orderedIDs.endIndex ? orderedIDs[next] : current

        case .moveUp:
            guard !orderedIDs.isEmpty else { return nil }
            guard let current = validSelection,
                  let index = orderedIDs.firstIndex(of: current)
            else {
                return orderedIDs.last
            }
            if index == orderedIDs.startIndex {
                return current
            }
            return orderedIDs[orderedIDs.index(before: index)]
        }
    }

    /// Keeps `selection` only when it is present for the current generation.
    static func resolvedSelection(
        _ selection: WorkspaceSearchResultRowID?,
        orderedIDs: [WorkspaceSearchResultRowID],
        queryGeneration: UInt64
    ) -> WorkspaceSearchResultRowID? {
        guard let selection else { return nil }
        guard selection.queryGeneration == queryGeneration else { return nil }
        guard orderedIDs.contains(selection) else { return nil }
        return selection
    }
}
