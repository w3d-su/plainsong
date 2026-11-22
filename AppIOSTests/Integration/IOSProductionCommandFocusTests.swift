import EditorKitIOS
import Foundation
import MarkdownCore
@testable import PlainsongIOS
import PreviewKit
import UIKit
import WorkspaceKitIOS
import XCTest

/// The keyboard bar (`IOSAuthoringKeyboardBar`) disables Undo/Redo without the
/// scene command route, and `IOSShellActionRouter.perform` refuses every bar
/// command without it. These cover the runtime paths that claim the route back.
@MainActor
final class IOSProductionCommandFocusTests: XCTestCase {
    /// A document opened from Files while the scene was inactive was never queued,
    /// because `noteNewBinding` only queues while active. Activation claims it.
    func testReturningActiveClaimsADocumentBoundWhileInactive() async throws {
        let harness = try makeHarness()
        harness.runtime.startObserving()
        harness.runtime.setSceneActive(false)
        let bindingID = UUID()
        harness.runtime.editor.attach(Self.binding(bindingID))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(Self.claims(in: harness.facade, bindingID), 0)
        harness.runtime.setSceneActive(true)
        try await waitUntil { Self.claims(in: harness.facade, bindingID) > 0 }
    }

    /// A read-only modal releases the route, and not every dismissal path claims
    /// it back. Putting the caret in the source does.
    func testBeginningToEditTheSourceClaimsTheRoute() async throws {
        let harness = try makeHarness()
        let bindingID = UUID()
        harness.runtime.editor.attach(Self.binding(bindingID))
        harness.runtime.scene.startObserving()
        defer { harness.runtime.scene.stopObserving() }
        harness.runtime.startObserving()
        try await waitUntil { Self.claims(in: harness.facade, bindingID) > 0 }
        harness.runtime.prepareForReadOnlyPresentation()
        let before = Self.claims(in: harness.facade, bindingID)

        Self.postBeginEditing(harness.runtime.editor.textView)
        try await waitUntil { Self.claims(in: harness.facade, bindingID) > before }
    }

    func testBeginningToEditBehindASheetDoesNotClaimTheRoute() async throws {
        let harness = try makeHarness()
        let bindingID = UUID()
        harness.runtime.editor.attach(Self.binding(bindingID))
        harness.runtime.scene.startObserving()
        defer { harness.runtime.scene.stopObserving() }
        harness.runtime.startObserving()
        try await waitUntil { Self.claims(in: harness.facade, bindingID) > 0 }
        harness.runtime.scene.present(.workspaceSearch)
        defer { harness.runtime.scene.dismissPresentation() }
        harness.runtime.prepareForReadOnlyPresentation()
        let before = Self.claims(in: harness.facade, bindingID)

        Self.postBeginEditing(harness.runtime.editor.textView)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(Self.claims(in: harness.facade, bindingID), before)
    }

    /// An iPad sheet with no text input leaves the source first responder, so no
    /// begin-editing event would follow its dismissal. A Zhuyin composition is
    /// left alone: resigning would commit its marked text.
    func testReadOnlyPresentationResignsTheSourceExceptDuringComposition() throws {
        let harness = try makeHarness()
        harness.runtime.editor.attach(Self.binding(UUID()))
        let textView = harness.runtime.editor.textView
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let host = UIViewController()
        window.rootViewController = host
        textView.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        host.view.addSubview(textView)
        window.makeKeyAndVisible()
        defer {
            textView.removeFromSuperview()
            window.isHidden = true
        }
        XCTAssertTrue(textView.becomeFirstResponder())
        textView.setMarkedText("ㄅ", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertNotNil(textView.markedTextRange)

        harness.runtime.prepareForReadOnlyPresentation()
        XCTAssertTrue(textView.isFirstResponder)
        XCTAssertNotNil(textView.markedTextRange)

        textView.unmarkText()
        harness.runtime.prepareForReadOnlyPresentation()
        XCTAssertFalse(textView.isFirstResponder)
    }

    private static func binding(_ bindingID: UUID) -> IOSSourceEditorDocumentBinding {
        IOSSourceEditorDocumentBinding(
            bindingID: bindingID, identity: IOSDocumentIdentity(rawValue: UUID()),
            session: DocumentSession(text: "# Draft", fileKind: .markdown),
            accessGeneration: 1, canWrite: true
        )
    }

    private static func claims(in facade: FakeSceneFacade, _ bindingID: UUID) -> Int {
        facade.setCommandFocusCalls.filter { $0.focused && $0.bindingID == bindingID }.count
    }

    private static func postBeginEditing(_ textView: UITextView) {
        NotificationCenter.default.post(name: UITextView.textDidBeginEditingNotification, object: textView)
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for a command-focus claim")
        throw IOSDocumentFailure.unavailable
    }

    private func makeHarness() throws -> (runtime: IOSProductionRuntime, facade: FakeSceneFacade) {
        let editor = IOSSourceEditorController()
        let preview = PreviewController()
        let assets = IOSWorkspaceAccessFactory.makeProduction(recentKey: "CommandFocusTests.\(UUID().uuidString)")
        let facade = FakeSceneFacade(capabilities: IOSSceneCapabilities(
            editor: editor, documents: nil, workspace: assets, preview: preview, assets: assets
        ))
        let runtime = try IOSProductionRuntime(
            controller: facade, editor: editor, preview: preview,
            currentGrant: { nil }, refreshWorkspace: {}, openPickedURL: { _, _ in }, shutdown: { true }
        )
        addTeardownBlock { @MainActor in
            runtime.stopObserving()
            runtime.preview.invalidate()
        }
        return (runtime, facade)
    }
}
