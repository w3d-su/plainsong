import MarkdownCore
import SwiftUI

/// Xcode-style jump bar: workspace › folders › document, with the file type trailing.
///
/// The document segment keeps the `plainsong.editor.fileName` identity that the UI tests use
/// to find the workspace window.
struct DocumentJumpBar: View {
    let rootURL: URL?
    let fileURL: URL?
    let fileKind: FileKind
    let isSaving: Bool

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(folderNames.enumerated()), id: \.offset) { index, name in
                let isRoot = index == 0 && rootURL != nil
                Label {
                    Text(name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: isRoot ? "folder.fill" : "folder")
                        .foregroundStyle(isRoot ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
                .foregroundStyle(.secondary)
                .layoutPriority(index == 0 ? 0.5 : 0)

                Image(systemName: "chevron.compact.right")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }

            Label {
                Text(fileName)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("plainsong.editor.fileName")
                    .accessibilityLabel("Current editor file")
                    .accessibilityValue(fileName)
            } icon: {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            if isSaving {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel("Saving")
            }

            Text(fileKind.displayName)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
        }
        .font(.callout)
        .labelStyle(JumpBarLabelStyle())
        .padding(.horizontal, 12)
        .frame(height: 30)
        .help(fileURL?.path(percentEncoded: false) ?? "Untitled")
    }

    private var fileName: String {
        fileURL?.lastPathComponent ?? "Untitled"
    }

    /// Root name plus intermediate folders when the document lives in the workspace,
    /// otherwise just the parent folder.
    private var folderNames: [String] {
        guard let fileURL else { return [] }
        let parent = fileURL.deletingLastPathComponent()
        if let rootURL {
            let rootComponents = rootURL.standardizedFileURL.pathComponents
            let parentComponents = parent.standardizedFileURL.pathComponents
            if parentComponents.starts(with: rootComponents) {
                return [rootURL.lastPathComponent] + parentComponents.dropFirst(rootComponents.count)
            }
        }
        return [parent.lastPathComponent]
    }
}

private struct JumpBarLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
                .imageScale(.small)
            configuration.title
        }
    }
}

extension FileKind {
    var displayName: String {
        switch self {
        case .markdown:
            "Markdown"
        case .mdx:
            "MDX"
        }
    }
}
