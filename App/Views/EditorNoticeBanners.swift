import SwiftUI

struct ExternalChangeBanner: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NoticeBar(
            tone: .caution,
            systemImage: "exclamationmark.triangle.fill",
            message: "This file changed on disk."
        ) {
            Button("Keep Mine") {
                appState.keepMineForExternallyChangedFile()
            }

            Button("Reload") {
                appState.reloadExternallyChangedFile()
            }
        }
    }
}

struct WYSIWYGFallbackBanner: View {
    @EnvironmentObject private var appState: AppState
    let message: String

    var body: some View {
        NoticeBar(
            tone: .neutral,
            systemImage: "wand.and.stars",
            message: message
        ) {
            Button("Dismiss") {
                appState.dismissWYSIWYGFallbackMessage()
            }
        }
    }
}
