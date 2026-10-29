@testable import EditorKit
import Foundation
import MarkdownCore
@testable import Plainsong
import WorkspaceKit
import XCTest

/// Windows PR B1: a container hook that `AppState` never connected reaches
/// `UnwiredContainerHook` (an `assertionFailure` in Debug) instead of silently skipping the
/// Replace authority advance or an Export as HTML… context change. `AppState`-built
/// containers never reach it.
@MainActor
final class WindowStatePartitionWiringAppTests: XCTestCase {
    func testUnwiredWindowStateReportsEachHookedInput() throws {
        let fixture = try WindowStatePartitionFixture.make(testCase: self)
        let recorder = UnwiredContainerHookRecorder()
        defer { recorder.stop() }
        let window = WindowState(
            shownSession: DocumentSession(text: "bare"),
            layoutMode: .sourceOnly,
            wysiwygFallbackMessage: nil,
            replaceAuthority: EditorReplaceAuthorityState()
        )

        for write in fixture.windowAuthorityWrites() {
            write.apply(window)
        }
        window.workspaceRootURL = fixture.location.fileURL.deletingLastPathComponent()

        let authority = recorder.reports(for: "WindowState.onEditorReplaceAuthorityInputChange")
        XCTAssertEqual(authority.count, 4)
        XCTAssertEqual(Set(authority.map(\.line)).count, 4, "Each report names its own hooked property")
        // `shownSession` and `workspaceRootURL` also record an export context change.
        let export = recorder.reports(for: "WindowState.onExportHTMLContextChange")
        XCTAssertEqual(export.count, 2)
        XCTAssertEqual(Set(export.map(\.line)).count, 2)
        XCTAssertEqual(recorder.reports.count, 6)
        XCTAssertTrue(recorder.reports.allSatisfy { $0.fileID == "Plainsong/WindowState.swift" })
    }

    func testUnwiredRegistryReportsEachAuthorityInput() throws {
        let fixture = try WindowStatePartitionFixture.make(testCase: self)
        let recorder = UnwiredContainerHookRecorder()
        defer { recorder.stop() }
        let registry = Self.makeBareRegistry()

        for write in fixture.registryAuthorityWrites() {
            write.apply(registry)
        }

        let authority = recorder.reports(for: "AppDocumentRegistry.onEditorReplaceAuthorityInputChange")
        XCTAssertEqual(authority.count, 12)
        XCTAssertEqual(Set(authority.map(\.line)).count, 12, "Each report names its own hooked property")
        XCTAssertEqual(recorder.reports.count, 12)
        XCTAssertTrue(recorder.reports.allSatisfy { $0.fileID == "Plainsong/AppDocumentRegistry.swift" })
    }

    func testUnwiredRootContextReportsItsExportInput() throws {
        let fixture = try WindowStatePartitionFixture.make(testCase: self)
        let recorder = UnwiredContainerHookRecorder()
        defer { recorder.stop() }
        let root = WorkspaceRootContext()

        root.workspaceAccess = SecurityScopedAccess.startAccessing(fixture.location.fileURL.deletingLastPathComponent())

        XCTAssertEqual(recorder.reports.map(\.hook), ["WorkspaceRootContext.onExportHTMLContextChange"])
        XCTAssertEqual(recorder.reports.first?.fileID, "Plainsong/WorkspaceRootContext.swift")
    }

    /// Every hooked input written directly on an `AppState`'s containers reaches `AppState`,
    /// so nothing is reported, the generation advances once per input, and the export
    /// context change is recorded.
    func testAppStateConnectsEveryContainerHook() throws {
        let fixture = try WindowStatePartitionFixture.make(testCase: self)
        let appState = fixture.appState
        let recorder = UnwiredContainerHookRecorder()
        defer { recorder.stop() }
        appState.exportHTMLOperations.activeOperationID = 1
        let before = appState.editorReplaceAuthorityGeneration

        for write in fixture.windowAuthorityWrites() {
            write.apply(appState.windowState)
        }
        for write in fixture.registryAuthorityWrites() {
            write.apply(appState.registry)
        }
        appState.windowState.workspaceRootURL = fixture.location.fileURL.deletingLastPathComponent()
        appState.workspaceRootContext.workspaceAccess = SecurityScopedAccess.startAccessing(
            fixture.location.fileURL.deletingLastPathComponent()
        )

        XCTAssertEqual(recorder.reports, [])
        XCTAssertGreaterThanOrEqual(appState.editorReplaceAuthorityGeneration - before, 16)
        XCTAssertEqual(appState.exportHTMLOperations.contextStopReason, .documentChanged)
    }

    private static func makeBareRegistry() -> AppDocumentRegistry {
        let userDefaults = UserDefaults(suiteName: "WindowStatePartitionWiringAppTests-\(UUID().uuidString)")!
        return AppDocumentRegistry(
            fileStore: MarkdownFileStore(),
            coherentFileReader: WorkspaceCoherentFileReader(),
            externalReloadApplicationPreparer: ProductionExternalReloadApplicationPreparer(),
            lastOpenedFileStore: LastOpenedFileStore(),
            recentItemStore: RecentItemStore(),
            directoryScanner: WorkspaceDirectoryScanner(),
            workspaceSearchStreamProvider: WorkspaceSearchService(),
            workspaceSearchLimits: .init(),
            workspaceSearchDebounceNanoseconds: 200_000_000,
            editorImageThumbnailAdapter: WorkspaceEditorImageThumbnailAdapter(
                provider: WorkspaceImageThumbnailProvider()
            ),
            fileOperations: WorkspaceFileOperations(),
            workspaceMutationOperationRecoveryStore: TransientMutationOperationStore(),
            workspaceMutationTextRecoveryStore: TransientMutationTextStore(),
            reportedTrashBookmarkAccess: ProductionReportedTrashBookmarkAccess(),
            shouldRestoreLastOpenedFile: false,
            userDefaults: userDefaults,
            preferences: PlainsongPreferences(userDefaults: userDefaults)
        )
    }
}
