import MarkdownCore
import SwiftUI
import WorkspaceKit

/// Xcode-style jump bar: workspace › folders › document, with the file type trailing.
///
/// Like Xcode's, every segment is live: a folder lists its contents, the document lists its
/// siblings, and a right click copies the name or path (`JumpBarMenuTarget`). The document
/// segment keeps the `plainsong.editor.fileName` static text the UI tests use to find the
/// workspace window.
struct DocumentJumpBar: View {
    /// The sidebar's navigator bar shares this row height so the two bottoms line up.
    static let height: CGFloat = 30

    let rootURL: URL?
    let fileURL: URL?
    let fileKind: FileKind
    let isSaving: Bool
    /// Read when a segment menu opens, never while laying out the bar.
    let workspaceTree: () -> WorkspaceFileTree?
    let openNode: (WorkspaceFileNode.ID) -> Void

    var body: some View {
        HStack(spacing: 1) {
            ForEach(folderSegments) { segment in
                Label {
                    Text(segment.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: segment.isRoot ? "folder.fill" : "folder")
                        .foregroundStyle(segment.isRoot ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
                .segmentPadding()
                .overlay {
                    JumpBarMenuTarget(
                        accessibilityLabel: segment.name,
                        hasPrimaryMenu: segment.treePath != nil,
                        primaryMenu: { folderMenu(path: segment.treePath) },
                        contextMenu: { JumpBarMenus.copyMenu(for: segment.url, rootURL: rootURL) }
                    )
                }
                .layoutPriority(segment.isRoot ? 0.5 : 0)

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
            .segmentPadding()
            .overlay {
                if let fileURL {
                    JumpBarMenuTarget(
                        accessibilityLabel: "Files in \(fileURL.deletingLastPathComponent().lastPathComponent)",
                        hasPrimaryMenu: folderSegments.last?.treePath != nil,
                        primaryMenu: { folderMenu(path: folderSegments.last?.treePath) },
                        contextMenu: { JumpBarMenus.copyMenu(for: fileURL, rootURL: rootURL) }
                    )
                }
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
        .padding(.horizontal, 8)
        .frame(height: Self.height)
        .help(fileURL?.path(percentEncoded: false) ?? "Untitled")
    }

    private var fileName: String {
        fileURL?.lastPathComponent ?? "Untitled"
    }

    private func folderMenu(path: [String]?) -> NSMenu? {
        guard let path else { return nil }
        return JumpBarMenus.folderMenu(
            path: path,
            tree: workspaceTree(),
            currentRelativePath: fileURL.flatMap { JumpBarMenus.relativePath(of: $0, under: rootURL) },
            open: openNode
        )
    }

    /// The workspace root and the folders down to the document, or just the parent folder
    /// for a document outside a workspace.
    private var folderSegments: [FolderSegment] {
        guard let fileURL else { return [] }
        let parent = fileURL.deletingLastPathComponent()
        if let rootURL,
           let relativeFolder = JumpBarMenus.relativePath(of: parent, under: rootURL)
        {
            let names = relativeFolder.split(separator: "/").map(String.init)
            var segments = [FolderSegment(name: rootURL.lastPathComponent, url: rootURL, treePath: [], isRoot: true)]
            for index in names.indices {
                let path = Array(names[...index])
                segments.append(FolderSegment(
                    name: names[index],
                    url: path.reduce(rootURL) { $0.appendingPathComponent($1, isDirectory: true) },
                    treePath: path,
                    isRoot: false
                ))
            }
            return segments
        }
        return [FolderSegment(name: parent.lastPathComponent, url: parent, treePath: nil, isRoot: false)]
    }
}

private struct FolderSegment: Identifiable {
    let name: String
    let url: URL
    /// Folder names below the workspace root, or `nil` outside a workspace.
    let treePath: [String]?
    let isRoot: Bool

    var id: String {
        url.path(percentEncoded: false)
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

private extension View {
    /// Room for the hover highlight drawn by `JumpBarMenuTarget`.
    func segmentPadding() -> some View {
        padding(.horizontal, 4).padding(.vertical, 2)
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
