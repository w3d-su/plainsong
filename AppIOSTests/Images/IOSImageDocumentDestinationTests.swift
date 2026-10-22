import EditorKitIOS
import Foundation
@testable import PlainsongIOS
import WorkspaceCore
@testable import WorkspaceKitIOS
import XCTest

/// Shell presentation, image controller, and the production asset-path planner.
@MainActor
final class IOSImageDocumentDestinationTests: XCTestCase {
    func testRootAndNestedDocumentsStageBesideTheDocument() async throws {
        let cases = [
            ("post.md", "assets/photo.png", "assets/photo.png"),
            ("notes/post.md", "notes/assets/photo.png", "assets/photo.png"),
        ]
        for (documentPath, rootRelative, markdownRelative) in cases {
            let grant = ShellFixtures.grant()
            let editor = ImageEditorFake(
                probe: InsertionProbe(),
                text: "Hello",
                selection: NSRange(location: 5, length: 0),
                accessGeneration: grant.accessGeneration
            )
            var surfaces = IOSShellFeatureSurfaces(imageInsertion: FakeImageInserter())
            surfaces.currentGrant = { grant }
            let scene = IOSShellSceneState(
                facade: FakeSceneFacade(
                    snapshot: ShellFixtures.sceneSnapshot(
                        document: ShellFixtures.storedDocument(path: documentPath)
                    ),
                    capabilities: IOSSceneCapabilities(
                        editor: nil, documents: nil, workspace: nil, preview: nil, assets: nil
                    )
                ),
                surfaces: surfaces
            )
            scene.startObserving()
            scene.present(.imagePicker)
            let destination = try XCTUnwrap(scene.sheetContext?.destination)
            let capturedGrant = try XCTUnwrap(scene.sheetContext?.grant)
            XCTAssertEqual(destination.relativePath, documentPath)

            let writer = DocumentPathImageWriter()
            let controller = IOSImageInsertionController(writer: writer)
            let session = IOSImageInsertionSession(
                controller: controller,
                editor: editor,
                destination: destination,
                grant: capturedGrant
            )
            let context = try XCTUnwrap(session.preparePicker())
            let outcome = await controller.insert(
                bytes: ImageBytes.png,
                contentType: "image/png",
                preferredFilename: "photo.png",
                context: context,
                using: editor
            )
            guard case .inserted = outcome else {
                XCTFail("\(documentPath) insert failed: \(String(describing: outcome))")
                continue
            }
            XCTAssertEqual(writer.destinations, [documentPath])
            XCTAssertEqual(writer.rootPaths, [rootRelative])
            XCTAssertEqual(writer.markdownPaths, [markdownRelative])
            XCTAssertEqual(editor.submitted.last?.result.replacementString, "![](\(markdownRelative))")
        }
    }
}

private final class DocumentPathImageWriter: IOSWorkspaceAssetWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var destinationStorage: [String] = []
    private var rootStorage: [String] = []
    private var markdownStorage: [String] = []

    var destinations: [String] {
        lock.lock()
        defer { lock.unlock() }
        return destinationStorage
    }

    var rootPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return rootStorage
    }

    var markdownPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return markdownStorage
    }

    private func record(destination: String, root: String, markdown: String) {
        lock.lock()
        destinationStorage.append(destination)
        rootStorage.append(root)
        markdownStorage.append(markdown)
        lock.unlock()
    }

    func stage(_ request: IOSImageAssetRequest, grant _: IOSWorkspaceGrant) async throws -> IOSStagedImageAsset {
        guard let paths = IOSWorkspacePathAuthority.uniquedAssetPaths(
            documentRelativePath: request.destination.relativePath,
            preferredFilename: request.preferredFilename,
            operationID: request.operationID,
            exists: { _ in false }
        ) else {
            throw IOSAssetStageFailure.failed(.invalidPath)
        }
        record(
            destination: request.destination.relativePath,
            root: paths.rootRelative,
            markdown: paths.markdownRelative
        )
        return IOSStagedImageAsset(
            operationID: request.operationID,
            targetLocation: IOSFileLocation(
                workspaceID: request.destination.workspaceID,
                accessGeneration: request.destination.accessGeneration,
                relativePath: paths.rootRelative,
                fileURL: request.destination.fileURL
                    .deletingLastPathComponent()
                    .appendingPathComponent(paths.markdownRelative),
                resourceID: IOSWorkspaceResourceIdentity(rawValue: Data("owned-leaf".utf8))
            ),
            relativePath: paths.markdownRelative,
            ownedFileIdentity: IOSWorkspaceResourceIdentity(rawValue: Data("owned-leaf".utf8)),
            ownershipToken: UUID()
        )
    }

    func validate(_: IOSStagedImageAsset) async throws {}

    func commit(_: IOSStagedImageAsset) async -> IOSAssetCommitOutcome {
        .committed
    }

    func rollback(_: IOSStagedImageAsset) async -> IOSAssetRollbackOutcome {
        .removed
    }
}
