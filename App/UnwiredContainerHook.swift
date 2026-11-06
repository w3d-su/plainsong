/// Where a container hook goes when `AppState` has not connected it
/// (`docs/window-state-gates.md` §3.2).
///
/// `WindowState`, `WorkspaceRootContext`, and `AppDocumentRegistry` call back into `AppState`
/// from their `didSet` hooks. An unconnected hook would skip the Replace authority advance,
/// so a stale Replace plan could still commit, or it would lose an Export as HTML… context
/// change. In B1 only `AppState.init` builds the containers, and it connects every hook
/// before any can fire. PR C, which creates more `WindowState`s, must do the same.
///
/// Debug builds stop at an unconnected call. `assertionFailure` does nothing in Release, so
/// there the call stays a silent no-op, as it was before this check existed.
@MainActor
enum UnwiredContainerHook {
    /// Test seam: when set, receives unconnected calls instead of `assertionFailure`.
    static var reportOverrideForTesting: (
        @MainActor (_ hook: StaticString, _ fileID: StaticString, _ line: UInt) -> Void
    )?

    /// `hook` names the container and callback; `fileID`/`line` name the hooked property.
    static func report(_ hook: StaticString, fileID: StaticString, line: UInt) {
        if let reportOverrideForTesting {
            reportOverrideForTesting(hook, fileID, line)
            return
        }
        assertionFailure("\(hook) was called before AppState connected it, from \(fileID):\(line)")
    }
}
