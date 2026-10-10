import SwiftUI

struct MissingFileBanner: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NoticeBar(
            tone: .critical,
            systemImage: "exclamationmark.octagon.fill",
            message: "This file is no longer on disk."
        ) {
            Button("Close") {
                appState.closeMissingFile()
            }

            Button("Save Copy…") {
                appState.saveMissingFileCopy()
            }
        }
    }
}
