import AppKit
import SwiftUI
import WorkspaceKit

/// Click target laid over one jump bar segment, like Xcode's: left click pops the segment's
/// menu, right click its copy menu, and hovering draws the segment highlight.
///
/// Menus are AppKit menus built only when clicked, so a large workspace costs nothing while
/// the jump bar re-renders on every edit. The target is its own accessibility pop-up button,
/// so the segment's text underneath keeps its identity (`plainsong.editor.fileName`).
struct JumpBarMenuTarget: NSViewRepresentable {
    let accessibilityLabel: String
    let primaryMenu: () -> NSMenu?
    let contextMenu: () -> NSMenu

    func makeNSView(context _: Context) -> TargetView {
        let view = TargetView()
        update(view)
        return view
    }

    func updateNSView(_ view: TargetView, context _: Context) {
        update(view)
    }

    private func update(_ view: TargetView) {
        view.primaryMenu = primaryMenu
        view.contextMenuProvider = contextMenu
        view.setAccessibilityLabel(accessibilityLabel)
    }

    final class TargetView: NSView {
        var primaryMenu: (() -> NSMenu?)?
        var contextMenuProvider: (() -> NSMenu)?
        private var isHovered = false {
            didSet { needsDisplay = true }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self
            ))
        }

        override func mouseEntered(with _: NSEvent) {
            isHovered = true
        }

        override func mouseExited(with _: NSEvent) {
            isHovered = false
        }

        override func draw(_: NSRect) {
            guard isHovered else { return }
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }

        override func mouseDown(with event: NSEvent) {
            guard let menu = primaryMenu?() else {
                return super.mouseDown(with: event)
            }
            popUp(menu)
        }

        override func menu(for _: NSEvent) -> NSMenu? {
            contextMenuProvider?()
        }

        private func popUp(_ menu: NSMenu) {
            let below = NSPoint(x: 0, y: isFlipped ? bounds.maxY + 4 : -4)
            menu.popUp(positioning: nil, at: below, in: self)
            isHovered = false
        }

        override func isAccessibilityElement() -> Bool {
            true
        }

        override func accessibilityRole() -> NSAccessibility.Role? {
            .popUpButton
        }

        override func accessibilityPerformPress() -> Bool {
            guard let menu = primaryMenu?() else { return false }
            popUp(menu)
            return true
        }

        override func accessibilityPerformShowMenu() -> Bool {
            guard let menu = contextMenuProvider?() else { return false }
            popUp(menu)
            return true
        }
    }
}

/// The menus behind the jump bar segments.
@MainActor
enum JumpBarMenus {
    /// The workspace folder at `path` (folder names below the root), or `nil` outside a
    /// workspace or when the tree no longer has that folder.
    static func folderMenu(
        path: [String],
        tree: WorkspaceFileTree?,
        currentRelativePath: String?,
        open: @escaping (WorkspaceFileNode.ID) -> Void
    ) -> NSMenu? {
        guard var node = tree?.root else { return nil }
        for name in path {
            guard let child = node.children.first(where: { $0.isDirectory && $0.name == name }) else {
                return nil
            }
            node = child
        }
        return WorkspaceFolderMenu(folder: node, currentRelativePath: currentRelativePath, open: open)
    }

    /// Finder-style copy actions for a segment's file or folder.
    static func copyMenu(for url: URL, rootURL: URL?) -> NSMenu {
        let menu = NSMenu()
        let name = url.lastPathComponent
        menu.addItem(ClosureMenuItem(title: "Copy “\(name)”") { copy(name) })
        menu.addItem(ClosureMenuItem(title: "Copy Path") { copy(url.path(percentEncoded: false)) })
        if let relativePath = relativePath(of: url, under: rootURL), !relativePath.isEmpty {
            menu.addItem(ClosureMenuItem(title: "Copy Relative Path") { copy(relativePath) })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        })
        return menu
    }

    /// `url`'s path below `rootURL`, joined with `/`, or `nil` when it is not inside it.
    static func relativePath(of url: URL, under rootURL: URL?) -> String? {
        guard let rootURL else { return nil }
        let rootComponents = rootURL.standardizedFileURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        guard components.starts(with: rootComponents) else { return nil }
        return components.dropFirst(rootComponents.count).joined(separator: "/")
    }

    private static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

/// One workspace folder's contents. Subfolder menus fill in only when opened.
private final class WorkspaceFolderMenu: NSMenu, NSMenuDelegate {
    private let folder: WorkspaceFileNode
    private let currentRelativePath: String?
    private let open: (WorkspaceFileNode.ID) -> Void

    init(folder: WorkspaceFileNode, currentRelativePath: String?, open: @escaping (WorkspaceFileNode.ID) -> Void) {
        self.folder = folder
        self.currentRelativePath = currentRelativePath
        self.open = open
        super.init(title: folder.name)
        // Non-Markdown files are listed but disabled, as in the sidebar.
        autoenablesItems = false
        delegate = self
    }

    @available(*, unavailable)
    required init(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.items.isEmpty else { return }
        guard !folder.children.isEmpty else {
            let empty = NSMenuItem(title: "No Items", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for child in folder.children {
            menu.addItem(item(for: child))
        }
    }

    private func item(for node: WorkspaceFileNode) -> NSMenuItem {
        if node.isDirectory {
            let item = NSMenuItem(title: node.name, action: nil, keyEquivalent: "")
            item.submenu = WorkspaceFolderMenu(folder: node, currentRelativePath: currentRelativePath, open: open)
            return item
        }
        let nodeID = node.id
        let open = open
        let item = ClosureMenuItem(title: node.name) { open(nodeID) }
        item.isEnabled = node.isEditableMarkdown
        item.state = node.relativePath == currentRelativePath ? .on : .off
        return item
    }
}

/// A menu item that runs a closure. It targets itself; the menu retains it.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(runHandler), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func runHandler() {
        handler()
    }
}
