import SwiftUI

/// Detail column with no document: Open… plus the most recent items.
struct EmptyEditorState: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ContentUnavailableView {
            Label("No Document", systemImage: "doc.text")
        } description: {
            Text("Open a Markdown or MDX file, or a folder of posts.")
        } actions: {
            VStack(spacing: 14) {
                Button("Open…") {
                    appState.openFile()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                if !recentURLs.isEmpty {
                    VStack(spacing: 2) {
                        Text("Recent")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 2)

                        ForEach(recentURLs, id: \.self) { url in
                            Button {
                                appState.openExternalFile(url)
                            } label: {
                                Label(url.lastPathComponent, systemImage: url.hasDirectoryPath ? "folder" : "doc.text")
                            }
                            .buttonStyle(.link)
                            .help(url.path(percentEncoded: false))
                        }
                    }
                }
            }
        }
    }

    private var recentURLs: [URL] {
        Array(appState.recentItemURLs.prefix(5))
    }
}
