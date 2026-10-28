import AppKit
@testable import EditorKit
import Foundation
import MarkdownCore
@testable import Plainsong
import WorkspaceKit
import XCTest

/// Windows PR B1 / gate W1 (`docs/window-state-gates.md` §3.2, §11): `AppState` keeps every
/// API while its stored properties live in `WindowState`, `WorkspaceRootContext`, and
/// `AppDocumentRegistry`.
@MainActor
final class WindowStatePartitionAppTests: XCTestCase {
    // MARK: - W1 bullet 1: every stored property follows §3.2

    /// A stored property added to `AppState` instead of its scope's container fails here.
    func testAppStateStoresOnlyItsContainers() {
        let appState = AppState(shouldRestoreLastOpenedFile: false)

        XCTAssertEqual(
            Self.storedPropertyNames(of: appState),
            ["containerChangeCancellables", "registry", "windowState", "workspaceRootContext"]
        )
    }

    func testEachContainerHoldsExactlyItsSection32Inventory() {
        let appState = AppState(shouldRestoreLastOpenedFile: false)

        XCTAssertEqual(
            Self.storedPropertyNames(of: appState.windowState),
            WindowStatePartitionInventory.window.union(["onEditorReplaceAuthorityInputChange",
                                                        "onExportHTMLContextChange"])
        )
        XCTAssertEqual(
            Self.storedPropertyNames(of: appState.workspaceRootContext),
            WindowStatePartitionInventory.root.union(["onExportHTMLContextChange"])
        )
        XCTAssertEqual(
            Self.storedPropertyNames(of: appState.registry),
            // `registeredWindows` is B2's window list for inventories (§3.4 I2).
            WindowStatePartitionInventory.registry.union(["onEditorReplaceAuthorityInputChange",
                                                          "replaceAuthority", "registeredWindows"])
        )
        XCTAssertEqual(
            WindowStatePartitionInventory.window.count + WindowStatePartitionInventory.root.count
                + WindowStatePartitionInventory.registry.count,
            121,
            "Every pre-B1 AppState stored property has exactly one home"
        )
        XCTAssertTrue(WindowStatePartitionInventory.window.isDisjoint(with: WindowStatePartitionInventory.root))
        XCTAssertTrue(WindowStatePartitionInventory.window.isDisjoint(with: WindowStatePartitionInventory.registry))
        XCTAssertTrue(WindowStatePartitionInventory.root.isDisjoint(with: WindowStatePartitionInventory.registry))
    }

    /// The façade reads and writes the container's storage, in both directions.
    func testFacadeAndContainerShareStorage() {
        let appState = AppState(shouldRestoreLastOpenedFile: false)
        let session = DocumentSession(text: "cached")
        let url = URL(fileURLWithPath: "/tmp/WindowStatePartitionAppTests/cached.md")

        appState.showAllFiles = true
        appState.workspaceGeneration = 7
        appState.registry.sessionCache[url] = session
        XCTAssertTrue(appState.windowState.showAllFiles)
        XCTAssertEqual(appState.workspaceRootContext.workspaceGeneration, 7)
        XCTAssertTrue(appState.registry.sessionCache[url] === session)

        appState.windowState.showAllFiles = false
        appState.workspaceRootContext.workspaceGeneration = 8
        appState.registry.sessionCache[url] = nil
        XCTAssertFalse(appState.showAllFiles)
        XCTAssertEqual(appState.workspaceGeneration, 8)
        XCTAssertNil(appState.registry.sessionCache[url])
    }

    // MARK: - W1 bullet 1: all 16 Replace authority inputs

    /// Each §3.2 authority input, written through the façade or directly on its container,
    /// advances the app-global generation and makes a plan captured before it stale. No
    /// write reaches `UnwiredContainerHook`: `AppState` connected every container hook.
    func testEveryAuthorityInputRefusesAStalePlanThroughFacadeAndContainer() throws {
        let fixture = try WindowStatePartitionFixture.make(testCase: self)
        let appState = fixture.appState
        let recorder = UnwiredContainerHookRecorder()
        defer { recorder.stop() }
        let cases = try fixture.authorityInputMutations()
        XCTAssertEqual(Set(cases.map(\.input)).count, 16)
        XCTAssertEqual(cases.count, 32, "Each input through the façade and through its container")

        for mutation in cases {
            let session = appState.currentDocument
            let record = EditorReplaceAuthorizationRecord()
            let authorization = appState.makeEditorReplaceCommitAuthorization(
                stamp: appState.currentEditorReplaceAuthorityStamp(for: session),
                session: session,
                record: record
            )
            let before = appState.editorReplaceAuthorityGeneration

            mutation.apply(appState)

            let label = "\(mutation.input) via \(mutation.path)"
            XCTAssertGreaterThan(appState.editorReplaceAuthorityGeneration, before, label)
            XCTAssertFalse(authorization.allowsCommit(), label)
            XCTAssertEqual(
                record.refusal,
                mutation.input == "currentDocument" ? .notCurrentSession : .authoritySuperseded,
                label
            )
        }
        XCTAssertEqual(recorder.reports, [])
    }

    /// §3.2 `editorFindHost` row: the window's Find host uses the registry's app-global
    /// generation, so a registry fence and a window prompt advance the same counter.
    func testEditorFindHostSharesTheRegistryReplaceAuthority() {
        let appState = AppState(shouldRestoreLastOpenedFile: false)

        XCTAssertTrue(appState.editorFindHost.replaceAuthority === appState.registry.replaceAuthority)
    }

    // MARK: - Export as HTML… context hooks

    func testCurrentDocumentChangeRecordsExportContextDocumentChanged() {
        let appState = AppState(shouldRestoreLastOpenedFile: false)
        appState.exportHTMLOperations.activeOperationID = 1

        appState.windowState.currentDocument = DocumentSession(text: "other")

        XCTAssertEqual(appState.exportHTMLOperations.contextStopReason, .documentChanged)
    }

    /// Reassigning the same instance is not a context change (the `!==` check moved too).
    func testSameCurrentDocumentRecordsNoExportContextChange() {
        let appState = AppState(shouldRestoreLastOpenedFile: false)
        appState.exportHTMLOperations.activeOperationID = 1

        appState.currentDocument = appState.currentDocument

        XCTAssertNil(appState.exportHTMLOperations.contextStopReason)
    }

    func testWorkspaceRootURLChangeRecordsExportContextWorkspaceChanged() {
        let appState = AppState(shouldRestoreLastOpenedFile: false)
        appState.exportHTMLOperations.activeOperationID = 1

        appState.workspaceRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WindowStatePartitionAppTests-\(UUID().uuidString)", isDirectory: true)

        XCTAssertEqual(appState.exportHTMLOperations.contextStopReason, .workspaceChanged)
    }

    func testWorkspaceAccessChangeRecordsExportContextWorkspaceChanged() throws {
        let appState = AppState(shouldRestoreLastOpenedFile: false)
        appState.exportHTMLOperations.activeOperationID = 1
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WindowStatePartitionAppTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        appState.workspaceRootContext.workspaceAccess = SecurityScopedAccess.startAccessing(directory)

        XCTAssertEqual(appState.exportHTMLOperations.contextStopReason, .workspaceChanged)
    }

    // MARK: - Helpers

    static func storedPropertyNames(of object: AnyObject) -> Set<String> {
        Set(Mirror(reflecting: object).children.compactMap { child in
            child.label.map { $0.hasPrefix("_") ? String($0.dropFirst()) : $0 }
        })
    }
}
