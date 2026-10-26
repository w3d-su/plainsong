import SwiftUI

/// Header row: document name, dirty indicator, kind badge, saving spinner.
/// Read-only/conflict/unavailable visibility comes from the deduplicated
/// chrome snapshot; actions stay with the facade.
struct IOSDocumentStatusChrome: View {
    let chrome: IOSShellChromeSnapshot

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(chrome.documentTitle)
                        .font(.headline)
                        .lineLimit(1)
                        .accessibilityIdentifier("plainsong.ios.editor.fileName")
                        .accessibilityLabel("Current file")

                    if chrome.isDirty {
                        Circle()
                            .fill(.orange)
                            .frame(width: 7, height: 7)
                            .accessibilityLabel("Edited")
                    }
                }

                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if !chrome.editorCanWrite, chrome.status == .ready {
                Text("Read Only")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
            }

            if let kind = chrome.documentKind {
                Text(kind == .mdx ? "MDX" : "Markdown")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
            }

            if chrome.isSaving {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Saving")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var statusLine: String {
        switch chrome.status {
        case .noDocument: "No file"
        case .opening: "Opening…"
        case .ready: chrome.isDirty ? "Edited" : "Saved"
        case .conflict: "Conflict"
        case .unavailable: "Unavailable"
        case .closed: "Closed"
        }
    }
}

/// Banners for non-ready document states. Buttons delegate to the facade;
/// "Save a Copy" is offered only when composition supplies the destination
/// flow (`resolveConflictCopy`), since it needs a picker + lease the shell
/// cannot derive (wiring request W14).
struct IOSDocumentStateBanner: View {
    let chrome: IOSShellChromeSnapshot
    let scene: IOSShellSceneState

    var body: some View {
        switch chrome.status {
        case .opening:
            banner(tint: .blue) {
                ProgressView().controlSize(.small)
                Text("Opening document…").font(.callout)
                Spacer()
            }
        case .conflict:
            banner(tint: .orange) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("File changed outside this editor").font(.callout.weight(.medium))
                    if let detail = chrome.statusDetail {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Reload") {
                    scene.resolveExternal(.reload)
                }
                .accessibilityHint("Replace editor contents with the file on disk")
                if let copy = scene.surfaces.resolveConflictCopy {
                    Button("Save a Copy", action: copy)
                }
            }
        case .unavailable:
            banner(tint: .red) {
                Image(systemName: "exclamationmark.octagon")
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Document unavailable").font(.callout.weight(.medium))
                    if let detail = chrome.statusDetail {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Try Again") {
                    scene.retryOpenUnavailableDocument()
                }
                if let copy = scene.surfaces.resolveConflictCopy {
                    Button("Save a Copy", action: copy)
                        .accessibilityHint("Save the retained text to a different folder without closing this document")
                }
            }
        case .ready, .noDocument, .closed:
            EmptyView()
        }
    }

    private func banner(
        tint _: Color,
        @ViewBuilder content: () -> some View
    ) -> some View {
        HStack(spacing: 10) { content() }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.yellow.opacity(0.16))
            .accessibilityElement(children: .contain)
    }
}

/// Empty document state for the detail column.
struct IOSEmptyDocumentView: View {
    let hasWorkspace: Bool

    var body: some View {
        ContentUnavailableView {
            Label("No File Open", systemImage: "doc.text.magnifyingglass")
        } description: {
            Text(hasWorkspace ? "Choose a file from the workspace." : "Open a file or folder to begin.")
        }
    }
}
