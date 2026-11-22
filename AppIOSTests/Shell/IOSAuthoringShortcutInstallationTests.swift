@testable import PlainsongIOS
import SwiftUI
import UIKit
import XCTest

/// Shortcuts have to be installed on mounted controls. Catalog uniqueness does
/// not prove a hardware key reaches the scene router.
@MainActor
final class IOSAuthoringShortcutInstallationTests: XCTestCase {
    /// The host mirrors the document column: navigation-bar items plus the
    /// keyboard bar, which carries the primary commands' shortcuts.
    func testToolbarInstallsEveryDescriptorShortcut() {
        let mounted = Self.mountDocumentScreen()
        defer { mounted.window.isHidden = true }
        Self.focusTextInput(in: mounted.host.view)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        let installed = Self.keyCommands(in: mounted.host)
        var expected = IOSAuthoringCatalog.actions.compactMap { action -> ExpectedShortcut? in
            guard let input = action.keyboardInput, input.count == 1, let character = input.first else { return nil }
            return ExpectedShortcut(
                input: String(character),
                flags: Self.flags(action.keyboardModifiers),
                name: "\(action.id)"
            )
        }
        expected.append(ExpectedShortcut(input: "z", flags: .command, name: "undo"))
        expected.append(ExpectedShortcut(input: "z", flags: [.command, .shift], name: "redo"))
        XCTAssertFalse(expected.isEmpty)
        let summary = installed.map { "\($0.input ?? "")/\($0.modifierFlags.rawValue)" }
        for item in expected {
            let matches = installed.filter { $0.input == item.input && $0.modifierFlags == item.flags }
            XCTAssertGreaterThanOrEqual(
                matches.count,
                1,
                "missing shortcut \(item.name) \(item.input) flags=\(item.flags.rawValue); saw \(summary)"
            )
        }
    }

    /// The keyboard bar is not mounted while a single pane shows the preview, but
    /// the Find button stays in the navigation bar there. Find, Find Next, Find
    /// Previous and Use Selection stay installed with it; the bar's own commands
    /// do not.
    func testPreviewLayoutKeepsTheFindShortcuts() {
        let mounted = Self.mountDocumentScreen()
        defer { mounted.window.isHidden = true }
        guard case .single = mounted.scene.layout else {
            return XCTFail("a 390 pt column shows one pane; got \(mounted.scene.layout)")
        }
        mounted.scene.showPane(.preview)
        mounted.host.view.setNeedsLayout()
        mounted.host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(mounted.scene.layout, .single(.preview))

        let installed = Self.keyCommands(in: mounted.host)
        let summary = installed.map { "\($0.input ?? "")/\($0.modifierFlags.rawValue)" }
        let findActions = IOSAuthoringCatalog.actions.filter { $0.placement == .find && $0.keyEquivalent != nil }
        XCTAssertEqual(findActions.map(\.id), [.find, .nextMatch, .previousMatch, .useSelectionForFind])
        for action in findActions {
            let input = action.keyboardInput ?? ""
            let flags = Self.flags(action.keyboardModifiers)
            XCTAssertTrue(
                installed.contains { $0.input == input && $0.modifierFlags == flags },
                "missing shortcut \(action.id) \(input) flags=\(flags.rawValue) in the preview; saw \(summary)"
            )
        }
        XCTAssertFalse(
            installed.contains { $0.input == "b" && $0.modifierFlags == .command },
            "the keyboard bar (⌘B) is still mounted, so this does not test the preview layout; saw \(summary)"
        )
    }

    private struct MountedDocumentScreen {
        let scene: IOSShellSceneState
        let window: UIWindow
        let host: UIViewController
    }

    /// The document column at iPhone width, with the editor stand-in mounted.
    private static func mountDocumentScreen() -> MountedDocumentScreen {
        let provider = FakeAuthoringProvider(actions: IOSAuthoringCatalog.actions)
        let editor = FakeEditorBinding()
        let scene = IOSShellSceneState(
            facade: FakeSceneFacade(
                snapshot: ShellFixtures.sceneSnapshot(document: ShellFixtures.storedDocument()),
                capabilities: IOSSceneCapabilities(
                    editor: editor, documents: nil, workspace: nil, preview: nil, assets: nil
                )
            ),
            surfaces: IOSShellFeatureSurfaces(
                authoring: provider,
                makeEditorView: { _ in UITextView() }
            )
        )
        scene.startObserving()
        let router = IOSShellActionRouter(scene: scene)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let host = UIHostingController(rootView: ShortcutToolbarHost(scene: scene, router: router))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        return MountedDocumentScreen(scene: scene, window: window, host: host)
    }

    private static func focusTextInput(in view: UIView) {
        if let field = view as? UITextField {
            field.becomeFirstResponder()
            return
        }
        if let textView = view as? UITextView {
            textView.becomeFirstResponder()
            return
        }
        for subview in view.subviews {
            focusTextInput(in: subview)
        }
    }

    private static func flags(_ modifiers: IOSKeyboardModifiers) -> UIKeyModifierFlags {
        var result: UIKeyModifierFlags = []
        if modifiers.contains(.command) {
            result.insert(.command)
        }
        if modifiers.contains(.shift) {
            result.insert(.shift)
        }
        if modifiers.contains(.option) {
            result.insert(.alternate)
        }
        if modifiers.contains(.control) {
            result.insert(.control)
        }
        return result
    }

    /// Every key command the mounted controls install. The editor stand-in's own commands
    /// are left out, so a match cannot come from `UITextView` (⌘Z in particular).
    private static func keyCommands(in host: UIViewController) -> [UIKeyCommand] {
        var commands: [UIKeyCommand] = []
        var responders: [UIResponder] = [host, host.view]
        var index = 0
        var seen = Set<ObjectIdentifier>()
        while index < responders.count {
            let responder = responders[index]
            index += 1
            guard seen.insert(ObjectIdentifier(responder)).inserted else { continue }
            guard !(responder is UITextView) else { continue }
            commands.append(contentsOf: responder.keyCommands ?? [])
            if let next = responder.next {
                responders.append(next)
            }
            if let view = responder as? UIView {
                responders.append(contentsOf: view.subviews)
            }
            if let controller = responder as? UIViewController, let presented = controller.presentedViewController {
                responders.append(presented)
            }
        }
        return commands
    }
}

private struct ExpectedShortcut {
    let input: String
    let flags: UIKeyModifierFlags
    let name: String
}

private struct ShortcutToolbarHost: View {
    @ObservedObject var scene: IOSShellSceneState
    @ObservedObject var router: IOSShellActionRouter

    var body: some View {
        NavigationStack {
            IOSDocumentScreen(scene: scene, router: router)
        }
    }
}
