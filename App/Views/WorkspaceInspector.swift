import AppKit
import MarkdownCore
import SwiftUI

/// Xcode-style document inspector: frontmatter fields and file details in plain headed
/// sections, hosted by `InspectorColumn`.
struct WorkspaceInspector: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        if appState.hasOpenDocument {
            DocumentInspectorForm(
                session: appState.currentDocument,
                rootURL: appState.workspaceRootURL
            ) { newText, session in
                appState.replaceDocumentText(newText, in: session)
            }
        } else {
            ContentUnavailableView(
                "No Document",
                systemImage: "sidebar.trailing",
                description: Text("Open a document to see its frontmatter and file details.")
            )
        }
    }
}

private struct DocumentInspectorForm: View {
    @ObservedObject var session: DocumentSession
    let rootURL: URL?
    let replaceText: (String, DocumentSession) -> Void

    /// Latest text seen on the session's change stream, or an edit made here that the
    /// session has not echoed yet.
    @State private var textSnapshot: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                InspectorSection("Frontmatter") {
                    FrontmatterRows(text: currentText) { newText in
                        textSnapshot = newText
                        replaceText(newText, session)
                    }
                }

                Divider()
                    .padding(.horizontal, 12)

                InspectorSection("File") {
                    InspectorRow("Name") {
                        Text(session.fileURL?.lastPathComponent ?? "Untitled")
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    InspectorRow("Type") {
                        Text(session.fileKind.displayName)
                    }
                    if let fileURL = session.fileURL {
                        InspectorRow("Location") {
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text(location(of: fileURL))
                                    .lineLimit(3)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                                Button {
                                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                                } label: {
                                    Image(systemName: "arrow.forward.circle.fill")
                                        .symbolRenderingMode(.hierarchical)
                                }
                                .buttonStyle(.borderless)
                                .help("Show in Finder")
                                .accessibilityLabel("Show in Finder")
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .controlSize(.small)
        .task(id: ObjectIdentifier(session)) {
            await observeSession()
        }
    }

    private var currentText: String {
        textSnapshot ?? session.text
    }

    @MainActor
    private func observeSession() async {
        textSnapshot = session.text
        for await change in session.textChanges(includeCurrent: true) {
            textSnapshot = change.text
        }
    }

    /// Folder path relative to the workspace root when inside it, else the full folder path.
    private func location(of fileURL: URL) -> String {
        let folder = fileURL.deletingLastPathComponent().standardizedFileURL
        if let rootURL {
            let root = rootURL.standardizedFileURL
            let rootComponents = root.pathComponents
            let folderComponents = folder.pathComponents
            if folderComponents.starts(with: rootComponents) {
                return ([root.lastPathComponent] + folderComponents.dropFirst(rootComponents.count))
                    .joined(separator: " › ")
            }
        }
        return folder.path(percentEncoded: false)
    }
}

/// An inspector section like Xcode's: a bold title over a two-column label/value grid.
/// Children that are not `InspectorRow`s span both columns.
struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 9) {
                content
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }
}

/// One inspector row: a trailing-aligned secondary label, then the value or control.
struct InspectorRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 88, alignment: .trailing)
                .gridColumnAlignment(.trailing)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
