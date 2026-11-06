import AppKit
import MarkdownCore
import SwiftUI

/// Xcode-style document inspector: frontmatter fields and file details in plain headed
/// sections, hosted by `InspectorColumn`.
struct WorkspaceInspector: View {
    @EnvironmentObject private var appState: AppState

    /// Folder path relative to the workspace root when inside it, else the full folder path.
    /// Uses `JumpBarMenus.relativePath` so a symlinked root resolves the same way.
    @MainActor
    static func location(of fileURL: URL, rootURL: URL?) -> String {
        let folder = fileURL.deletingLastPathComponent().standardizedFileURL
        guard let relativePath = JumpBarMenus.relativePath(of: folder, under: rootURL) else {
            return folder.path(percentEncoded: false)
        }
        let segments = ([rootURL?.lastPathComponent ?? ""]
            + relativePath.split(separator: "/").map(String.init))
        return segments.joined(separator: " › ")
    }

    var body: some View {
        DocumentInspectorForm(
            session: appState.shownSession,
            rootURL: appState.workspaceRootURL
        ) { newText, session in
            appState.replaceDocumentText(newText, in: session)
        }
    }
}

private struct DocumentInspectorForm: View {
    @ObservedObject var session: DocumentSession
    let rootURL: URL?
    let replaceText: (String, DocumentSession) -> Void

    /// Parsed frontmatter shown by the rows. Assigned only when the parse result changes.
    @State private var frontmatter = FrontmatterParseResult(block: nil)
    /// Not observed: holds the last parsed frontmatter prefix so body-only edits skip Yams.
    @State private var frontmatterMemo = FrontmatterParseMemo()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                InspectorSection("Frontmatter") {
                    FrontmatterRows(
                        result: frontmatter,
                        currentText: { session.text },
                        replaceText: { newText in
                            replaceText(newText, session)
                            // Show an edit made here at once; the debounced echo is a no-op.
                            refreshFrontmatter(from: session.text)
                        }
                    )
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
                                Text(WorkspaceInspector.location(of: fileURL, rootURL: rootURL))
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

    private func refreshFrontmatter(from text: String) {
        if frontmatterMemo.update(text: text) {
            frontmatter = frontmatterMemo.result
        }
    }

    /// Follows the session's text with a debounce: typing in the editor must not re-render
    /// the inspector (or re-parse its frontmatter) on every keystroke.
    @MainActor
    private func observeSession() async {
        refreshFrontmatter(from: session.text)
        var debounce: Task<Void, Never>?
        defer { debounce?.cancel() }
        for await change in session.textChanges(includeCurrent: false) {
            debounce?.cancel()
            let text = change.text
            debounce = Task { @MainActor in
                try? await Task.sleep(for: InspectorTiming.textDebounce)
                guard !Task.isCancelled else { return }
                refreshFrontmatter(from: text)
            }
        }
    }
}

enum InspectorTiming {
    static let textDebounce: Duration = .milliseconds(150)
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
