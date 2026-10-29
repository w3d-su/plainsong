import SwiftUI

/// Plainsong › Check for Updates…, placed after About. Hidden entirely when
/// updates are disabled; when shown, enablement follows `canCheckForUpdates`.
struct CheckForUpdatesButton: View {
    @ObservedObject var model: CheckForUpdatesModel

    var body: some View {
        Button("Check for Updates…", action: model.checkForUpdates)
            .disabled(!model.canCheckForUpdates)
    }
}
