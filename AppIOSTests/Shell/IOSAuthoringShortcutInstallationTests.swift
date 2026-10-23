@testable import PlainsongIOS
import SwiftUI
import UIKit
import XCTest

/// Shortcuts have to be installed on mounted controls. Catalog uniqueness does
/// not prove a hardware key reaches the scene router.
@MainActor
final class IOSAuthoringShortcutInstallationTests: XCTestCase {
    func testToolbarInstallsEveryDescriptorShortcut() {
        let provider = FakeAuthoringProvider(actions: IOSAuthoringCatalog.actions)
        let editor = FakeEditorBinding()
        let scene = IOSShellSceneState(
            facade: FakeSceneFacade(
                snapshot: ShellFixtures.sceneSnapshot(document: ShellFixtures.storedDocument()),
                capabilities: IOSSceneCapabilities(
                    editor: editor, documents: nil, workspace: nil, preview: nil, assets: nil
                )
            ),
            surfaces: IOSShellFeatureSurfaces(authoring: provider)
        )
        scene.startObserving()
        let router = IOSShellActionRouter(scene: scene)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let host = UIHostingController(rootView: ShortcutToolbarHost(scene: scene, router: router))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        Self.focusTextInput(in: host.view)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        let installed = Self.keyCommands(in: host)
        let expected = IOSAuthoringCatalog.actions.compactMap { action -> (
            String,
            UIKeyModifierFlags,
            IOSAuthoringActionID
        )? in
            guard let input = action.keyboardInput, input.count == 1, let character = input.first else { return nil }
            return (String(character), Self.flags(action.keyboardModifiers), action.id)
        }
        XCTAssertFalse(expected.isEmpty)
        for (input, flags, id) in expected {
            let matches = installed.filter { $0.input == input && $0.modifierFlags == flags }
            XCTAssertGreaterThanOrEqual(
                matches.count,
                1,
                "missing installed shortcut \(id) \(input) flags=\(flags.rawValue); saw \(installed.map { "\($0.input ?? "")/\($0.modifierFlags.rawValue)" })"
            )
        }
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

    private static func keyCommands(in host: UIViewController) -> [UIKeyCommand] {
        var commands: [UIKeyCommand] = []
        var responders: [UIResponder] = [host, host.view]
        var index = 0
        var seen = Set<ObjectIdentifier>()
        while index < responders.count {
            let responder = responders[index]
            index += 1
            guard seen.insert(ObjectIdentifier(responder)).inserted else { continue }
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

private struct ShortcutToolbarHost: View {
    @ObservedObject var scene: IOSShellSceneState
    @ObservedObject var router: IOSShellActionRouter

    var body: some View {
        NavigationStack {
            TextField("Editor", text: .constant("hello"))
                .toolbar {
                    IOSAuthoringToolbarItems(scene: scene, router: router)
                }
        }
    }
}
