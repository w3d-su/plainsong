import SwiftUI

struct MissingFileBanner: View {
    @EnvironmentObject private var appState: AppState
    @State private var isConfirmingClose = false

    var body: some View {
        NoticeBar(
            tone: .critical,
            systemImage: "exclamationmark.octagon.fill",
            message: "This file is no longer on disk."
        ) {
            Button("Close") {
                isConfirmingClose = true
            }

            Button("Save Copy…") {
                appState.saveMissingFileCopy()
            }
        }
        // The file is gone, so the editor holds the only copy of this text. Close used to
        // discard it with one click; it now asks first and offers Save Copy (M2).
        .confirmationDialog(
            "Close “\(fileName)” without saving a copy?",
            isPresented: $isConfirmingClose,
            titleVisibility: .visible
        ) {
            Button("Close Without Saving", role: .destructive) {
                appState.closeMissingFile()
            }
            Button("Save Copy…") {
                appState.saveMissingFileCopy()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            // Evaluated when the dialog opens. Detached documents are always marked edited,
            // because nothing on disk holds their text any more, so say which case this is.
            if appState.missingFileHasEditsBeyondLastDiskText {
                Text("Your unsaved edits exist only in the editor. Closing discards them.")
            } else {
                Text(
                    "The editor still shows the file's last saved text, which is no longer on disk. "
                        + "Closing discards it."
                )
            }
        }
    }

    private var fileName: String {
        appState.missingFilePrompt?.fileURL.lastPathComponent ?? "this document"
    }
}
