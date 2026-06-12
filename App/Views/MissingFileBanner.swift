import SwiftUI

struct MissingFileBanner: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.octagon")
                .foregroundStyle(.red)

            Text("File no longer on disk:")
                .font(.callout.weight(.medium))

            Button("Save Copy...") {
                appState.saveMissingFileCopy()
            }

            Button("Close") {
                appState.closeMissingFile()
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.red.opacity(0.12))
    }
}
