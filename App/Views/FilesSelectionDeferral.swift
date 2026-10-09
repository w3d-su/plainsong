import Foundation
import WorkspaceKit

/// One Files list's deferred selection open (R22).
///
/// `List(selection:)` applies arrow-key and click selection through NavigationAuthority
/// inside its own view update, so the binding setter must not synchronously publish
/// through `AppState` ("Publishing changes from within view updates"). The setter records
/// the pick here and opens it on the next main-actor turn.
///
/// Held in `@State` as a reference type: mutating these properties must not trigger a
/// SwiftUI update, so they are plain `var`s, not published.
@MainActor
final class FilesSelectionDeferral {
    /// The newest pick not yet applied to `AppState`; the List binding reads it so the
    /// next arrow press advances from the just-chosen row before the deferred open runs.
    var pendingID: WorkspaceFileNode.ID?
    /// Total picks handed to the deferral. `applied` tracks the newest pick that ran.
    var issued = 0
    var applied = 0
}
