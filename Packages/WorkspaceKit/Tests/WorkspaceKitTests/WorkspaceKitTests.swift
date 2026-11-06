@testable import WorkspaceKit
import XCTest

final class WorkspaceKitTests: XCTestCase {
    func testModuleLoads() {
        XCTAssertFalse(WorkspaceKitInfo.version.isEmpty)
    }

    func testLoadReadsUTF8MarkdownFile() throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("post.md")
        try "Hello **M1**\n".write(to: url, atomically: true, encoding: .utf8)

        let file = try MarkdownFileStore().load(url: url)

        XCTAssertEqual(file.url, url)
        XCTAssertEqual(file.text, "Hello **M1**\n")
        XCTAssertEqual(file.fileKind.rawValue, "markdown")
    }

    func testSaveWritesUTF8MDXFile() throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("component.mdx")

        try MarkdownFileStore().save(text: "# Title\n\n<Component />\n", to: url)

        let savedText = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(savedText, "# Title\n\n<Component />\n")
    }

    func testSaveReplacesExistingUTF8MarkdownFile() throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("post.md")
        try "Original".write(to: url, atomically: true, encoding: .utf8)

        try MarkdownFileStore().save(text: "Changed", to: url)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "Changed")
    }

    func testLegacyURLSaveFinishesWhenSchedulingTaskCancelsItself() async throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("post.md")
        try "Original".write(to: url, atomically: true, encoding: .utf8)

        let error = await Task.detached { () -> Error? in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try MarkdownFileStore().save(text: "Changed", to: url)
                return nil
            } catch {
                return error
            }
        }.value

        XCTAssertNil(error)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "Changed")
    }

    func testLegacySaveOutcomeMappingPreservesCleanupArtifacts() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destinationURL = directory.appendingPathComponent("post.md")
        try "Original".write(to: destinationURL, atomically: true, encoding: .utf8)
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: directory)
        let destination = try authority.location(relativePath: "post.md")
        let artifact = try authority.location(relativePath: ".post.recovery")
        let metadata = try MarkdownFileStore().loadResult(at: destination).metadata

        XCTAssertNoThrow(
            try MarkdownFileStore.mapLegacySaveOutcome(
                .committedAndDurable(
                    WorkspaceDurableFileWrite(metadata: metadata, cleanupState: .none)
                ),
                destinationURL: destinationURL
            )
        )

        for cleanupState in [
            WorkspaceFileWriteArtifactState.retained(artifact),
            .removalIndeterminate(artifact),
        ] {
            let durable = WorkspaceDurableFileWrite(
                metadata: metadata,
                cleanupState: cleanupState
            )
            XCTAssertThrowsError(
                try MarkdownFileStore.mapLegacySaveOutcome(
                    .committedAndDurable(durable),
                    destinationURL: destinationURL
                )
            ) { error in
                XCTAssertEqual(
                    error as? MarkdownFileStoreError,
                    .committedWithCleanupRequired(destinationURL, durable)
                )
            }
        }

        let notCommitted = WorkspaceNotCommittedFileWrite(
            reason: .durabilityFailed,
            artifactState: .retained(artifact)
        )
        XCTAssertThrowsError(
            try MarkdownFileStore.mapLegacySaveOutcome(
                .notCommitted(notCommitted),
                destinationURL: destinationURL
            )
        ) { error in
            XCTAssertEqual(
                error as? MarkdownFileStoreError,
                .writeNotCommittedWithCleanupRequired(destinationURL, notCommitted)
            )
        }
    }

    func testRejectsUnsupportedExtensions() throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("notes.txt")

        XCTAssertThrowsError(try MarkdownFileStore().load(url: url)) { error in
            XCTAssertEqual(error as? MarkdownFileStoreError, .unsupportedExtension(url))
        }

        XCTAssertThrowsError(try MarkdownFileStore().save(text: "Nope", to: url)) { error in
            XCTAssertEqual(error as? MarkdownFileStoreError, .unsupportedExtension(url))
        }
    }

    func testLoadRejectsInvalidUTF8() throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("binary.md")
        try Data([0xFF, 0xFE, 0xFD]).write(to: url)

        XCTAssertThrowsError(try MarkdownFileStore().load(url: url)) { error in
            XCTAssertEqual(error as? MarkdownFileStoreError, .unreadable(url))
        }
    }

    func testFileStoreErrorsHaveUserReadableDescriptions() {
        let unsupportedURL = URL(fileURLWithPath: "/tmp/notes.txt")
        let unreadableURL = URL(fileURLWithPath: "/tmp/binary.md")
        let unwritableURL = URL(fileURLWithPath: "/tmp/locked.mdx")

        XCTAssertEqual(
            MarkdownFileStoreError.unsupportedExtension(unsupportedURL).localizedDescription,
            "notes.txt is not a supported Markdown or MDX file."
        )
        XCTAssertEqual(
            MarkdownFileStoreError.unreadable(unreadableURL).localizedDescription,
            "Could not read binary.md as UTF-8 Markdown."
        )
        XCTAssertEqual(
            MarkdownFileStoreError.unwritable(unwritableURL).localizedDescription,
            "Could not save changes to locked.mdx."
        )
    }

    func testWriteRefusalsExplainTheCauseAndTheNextStep() {
        let url = URL(fileURLWithPath: "/Volumes/USB/post.md")

        XCTAssertEqual(
            MarkdownFileStoreError.unsupportedVolume(url).localizedDescription,
            "Could not save changes to post.md because its disk cannot replace files safely. Plainsong " +
                "saves by swapping in a complete new copy in one step, which disks formatted as exFAT, " +
                "FAT32, or Mac OS Extended do not support. Copy the file to a folder on your Mac or to " +
                "an APFS disk and edit it there."
        )
        XCTAssertEqual(
            MarkdownFileStoreError.insufficientSpace(url).localizedDescription,
            "Could not save changes to post.md because its disk is full. Free up space on the disk, " +
                "then save again."
        )
        XCTAssertEqual(
            MarkdownFileStoreError.readOnlyVolume(url).localizedDescription,
            "Could not save changes to post.md because its disk is read-only. Copy the file to a " +
                "folder you can write to and edit it there."
        )
        XCTAssertEqual(
            MarkdownFileStoreError.writeNotPermitted(url).localizedDescription,
            "Could not save changes to post.md because writing to it is not permitted. The file may " +
                "be locked, its permissions may have changed, or access to its folder may have been " +
                "revoked. Check the file with Get Info in the Finder, or open it again."
        )
    }

    func testNotCommittedErrorKeepsArtifactsAndNamesActionableReasons() throws {
        let destinationURL = URL(fileURLWithPath: "/tmp/post.md")
        let reasons: [(WorkspaceAnchoredFileSystemError, MarkdownFileStoreError)] = [
            (.unsupportedVolume, .unsupportedVolume(destinationURL)),
            (.insufficientSpace, .insufficientSpace(destinationURL)),
            (.readOnlyVolume, .readOnlyVolume(destinationURL)),
            (.writeNotPermitted, .writeNotPermitted(destinationURL)),
            (.unreadable, .unwritable(destinationURL)),
            (.durabilityFailed, .unwritable(destinationURL)),
            (.namespaceChanged, .unwritable(destinationURL)),
        ]
        for (reason, expected) in reasons {
            let result = WorkspaceNotCommittedFileWrite(reason: reason, artifactState: .none)
            XCTAssertEqual(MarkdownFileStoreError.notCommitted(result, destinationURL: destinationURL), expected)
            XCTAssertThrowsError(
                try MarkdownFileStore.mapLegacySaveOutcome(.notCommitted(result), destinationURL: destinationURL)
            ) { error in
                XCTAssertEqual(error as? MarkdownFileStoreError, expected)
            }
        }

        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifact = try WorkspaceFileSystemRootAuthority(rootURL: root)
            .location(relativePath: ".plainsong-write-1.tmp")
        let full = WorkspaceNotCommittedFileWrite(reason: .insufficientSpace, artifactState: .retained(artifact))
        let fullError = MarkdownFileStoreError.notCommitted(full, destinationURL: destinationURL)
        XCTAssertEqual(fullError, .writeNotCommittedWithCleanupRequired(destinationURL, full))
        XCTAssertEqual(
            fullError.localizedDescription,
            "post.md was not replaced because its disk is full, but a recovery artifact was retained at " +
                "\(artifact.fileURL.path)."
        )
        let generic = WorkspaceNotCommittedFileWrite(reason: .unreadable, artifactState: .retained(artifact))
        XCTAssertEqual(
            MarkdownFileStoreError.notCommitted(generic, destinationURL: destinationURL).localizedDescription,
            "post.md was not replaced, but a recovery artifact was retained at \(artifact.fileURL.path)."
        )
    }

    func testLastOpenedFileStorePersistsRestoresAndClearsBookmark() throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("post.markdown")
        try "Restored".write(to: url, atomically: true, encoding: .utf8)
        let suiteName = "Plainsong.WorkspaceKitTests.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }
        let store = LastOpenedFileStore(userDefaults: userDefaults, key: "lastOpened")

        do {
            try store.save(url)
        } catch {
            throw XCTSkip("Security-scoped bookmarks are unavailable in this test environment: \(error)")
        }

        let restoredURL = try XCTUnwrap(store.restore())
        XCTAssertEqual(restoredURL.standardizedFileURL, url.standardizedFileURL)

        store.clear()
        XCTAssertNil(try store.restore())
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceKitTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
