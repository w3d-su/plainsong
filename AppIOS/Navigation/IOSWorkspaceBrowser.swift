import SwiftUI
import WorkspaceCore

/// File navigation for both size classes: the compact stack's root and the
/// regular split view's sidebar. Lists the facade's workspace entries —
/// tapping a document delegates to `facade.openSelectedURL` via the scene
/// state; the shell never reads or mutates files itself.
struct IOSWorkspaceBrowserView: View {
    @ObservedObject var scene: IOSShellSceneState

    var body: some View {
        Group {
            if scene.sceneWorkspaceEntries.isEmpty {
                IOSEmptyWorkspaceView(hasWorkspace: scene.chrome.hasWorkspace) {
                    scene.surfaces.openWorkspace?()
                }
            } else {
                entryList
            }
        }
        .navigationTitle("Files")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if let showRecents = scene.surfaces.showRecentWorkspaces {
                    Button(action: showRecents) {
                        Label("Recent Files and Folders", systemImage: "clock")
                    }
                    .accessibilityIdentifier("plainsong.ios.browser.recents")
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let openWorkspace = scene.surfaces.openWorkspace {
                    Button {
                        openWorkspace()
                    } label: {
                        Label("Open File or Folder", systemImage: "folder.badge.plus")
                    }
                    .accessibilityIdentifier("plainsong.ios.browser.open")
                }
                Button {
                    scene.createDocument()
                } label: {
                    Label("New File", systemImage: "doc.badge.plus")
                }
                .disabled(scene.newFileTarget == nil)
                .accessibilityIdentifier("plainsong.ios.browser.newFile")
                if let refresh = scene.surfaces.refreshWorkspace {
                    Button {
                        refresh()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .accessibilityIdentifier("plainsong.ios.browser.refresh")
                }
            }
        }
    }

    private var entryList: some View {
        List(scene.sceneWorkspaceEntries, children: \.outlineChildren, selection: $scene.selectedEntryID) { entry in
            IOSWorkspaceEntryRow(entry: entry)
                .contentShape(Rectangle())
                .onTapGesture {
                    scene.openEntry(entry)
                    scene.navigateToDocument()
                }
                .disabled(!isTappable(entry))
        }
        .listStyle(.sidebar)
    }

    private func isTappable(_ entry: IOSWorkspaceEntry) -> Bool {
        guard case .document = entry.kind else { return false }
        guard case .available = entry.availability else { return false }
        return true
    }
}

private struct IOSWorkspaceEntryRow: View {
    let entry: IOSWorkspaceEntry

    var body: some View {
        Label {
            Text(name)
                .lineLimit(1)
        } icon: {
            Image(systemName: iconName)
                .foregroundStyle(iconTint)
        }
        .opacity(isDimmed ? 0.45 : 1)
        .accessibilityLabel("\(name), \(kindDescription)")
        .accessibilityHint(accessibilityHint)
        .accessibilityIdentifier("plainsong.ios.browser.entry.\(name)")
        .frame(minHeight: 44)
    }

    private var name: String {
        let path = entry.location.relativePath
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }

    private var iconName: String {
        switch entry.kind {
        case .directory: "folder"
        case let .document(kind): kind == .mdx ? "doc.text" : "doc.plaintext"
        case .image: "photo"
        case .other: "doc"
        }
    }

    private var iconTint: Color {
        switch entry.kind {
        case .directory: .accentColor
        default: .secondary
        }
    }

    private var isDimmed: Bool {
        switch entry.availability {
        case .available: false
        case .downloading, .offline, .unavailable, .removed: true
        }
    }

    private var kindDescription: String {
        switch entry.kind {
        case .directory: "folder"
        case let .document(kind): kind == .mdx ? "MDX document" : "Markdown document"
        case .image: "image"
        case .other: "file"
        }
    }

    private var accessibilityHint: String {
        switch entry.availability {
        case let .available(canWrite):
            canWrite ? "Double-tap to open" : "Read only; double-tap to open"
        case .downloading: "Downloading"
        case .offline: "Offline"
        case .unavailable: "Unavailable"
        case .removed: "Removed"
        }
    }
}

private struct IOSEmptyWorkspaceView: View {
    let hasWorkspace: Bool
    let onOpen: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(hasWorkspace ? "Empty Workspace" : "No Workspace", systemImage: "folder")
        } description: {
            Text(hasWorkspace
                ? "No Markdown files were found here."
                : "Open a Markdown file or a folder to browse its contents.")
        } actions: {
            Button("Open File or Folder", action: onOpen)
                .buttonStyle(.borderedProminent)
        }
    }
}

private extension IOSWorkspaceEntry {
    /// `List(children:)` needs an optional key path; empty directories collapse.
    var outlineChildren: [IOSWorkspaceEntry]? {
        children.isEmpty ? nil : children
    }
}
