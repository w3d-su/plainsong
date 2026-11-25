import AppKit
@testable import Plainsong
import XCTest

/// WD3 and W0 bullet 1's shortcut check, against the app's real menu bar, which SwiftUI builds
/// from `PlainsongCommands` in the hosted test app.
@MainActor
final class WindowMenuCommandsAppTests: XCTestCase {
    private struct Shortcut: Hashable, CustomStringConvertible {
        let key: String
        let modifiers: NSEvent.ModifierFlags.RawValue

        init?(_ item: NSMenuItem) {
            guard !item.keyEquivalent.isEmpty else { return nil }
            var flags = item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control])
            // AppKit spells a shifted letter as its capital.
            if item.keyEquivalent != item.keyEquivalent.lowercased() {
                flags.insert(.shift)
            }
            key = item.keyEquivalent.lowercased()
            modifiers = flags.rawValue
        }

        init(_ key: String, _ flags: NSEvent.ModifierFlags) {
            self.key = key
            modifiers = flags.rawValue
        }

        var description: String {
            let flags = NSEvent.ModifierFlags(rawValue: modifiers)
            var text = ""
            if flags.contains(.control) { text += "⌃" }
            if flags.contains(.option) { text += "⌥" }
            if flags.contains(.shift) { text += "⇧" }
            if flags.contains(.command) { text += "⌘" }
            return text + key.uppercased()
        }
    }

    func testFileMenuHasNewFileAndNewWindowAndNoItemSharesNewWindowsShortcut() throws {
        let items = try menuItems()
        let file = try XCTUnwrap(NSApp.mainMenu?.items.first { $0.submenu?.title == "File" }?.submenu)
        let newFile = try XCTUnwrap(file.items.first { $0.title == "New File" })
        let newWindow = try XCTUnwrap(file.items.first { $0.title == "New Window" })
        XCTAssertEqual(Shortcut(newFile), Shortcut("n", .command), "⌘N stays New File (WD3)")
        XCTAssertEqual(Shortcut(newWindow), Shortcut("n", [.command, .shift]), "New Window is ⇧⌘N (WD3)")

        let close = try XCTUnwrap(file.items.first { $0.title == "Close" }, "File › Close closes the key window")
        XCTAssertEqual(Shortcut(close), Shortcut("w", .command))

        let holders = items.filter { Shortcut($0) == Shortcut("n", [.command, .shift]) }
        XCTAssertEqual(holders.map(\.title), ["New Window"], "no app or system item shares ⇧⌘N")
        XCTAssertEqual(items.filter { $0.title == "New Window" }.count, 1, "the system New Window item stays replaced")
    }

    /// Records every key equivalent, for W0 bullet 1 and for PR F's ⌘T check.
    func testRecordMenuShortcuts() throws {
        let items = try menuItems()
        var lines: [String] = []
        var seen: [Shortcut: [String]] = [:]
        for item in items {
            guard let shortcut = Shortcut(item) else { continue }
            seen[shortcut, default: []].append(path(of: item))
        }
        for (shortcut, titles) in seen.sorted(by: { $0.key.description < $1.key.description }) {
            lines.append("\(shortcut): \(titles.joined(separator: " | "))")
        }
        let attachment = XCTAttachment(string: lines.joined(separator: "\n"))
        attachment.name = "Menu key equivalents"
        attachment.lifetime = .keepAlways
        add(attachment)
        print(lines.joined(separator: "\n"))
        let duplicates = seen.filter { $0.value.count > 1 }
        XCTAssertTrue(duplicates.isEmpty, "shared shortcuts: \(duplicates)")
    }

    private func menuItems() throws -> [NSMenuItem] {
        let menu = try XCTUnwrap(NSApp.mainMenu, "the hosted app built its menu bar")
        var items: [NSMenuItem] = []
        func collect(_ menu: NSMenu) {
            for item in menu.items {
                items.append(item)
                if let submenu = item.submenu {
                    collect(submenu)
                }
            }
        }
        collect(menu)
        return items
    }

    private func path(of item: NSMenuItem) -> String {
        var parts = [item.title]
        var menu = item.menu
        while let current = menu, let parent = current.supermenu {
            if let owner = parent.items.first(where: { $0.submenu === current }) {
                parts.insert(owner.title, at: 0)
            }
            menu = parent
        }
        return parts.joined(separator: " › ")
    }
}
