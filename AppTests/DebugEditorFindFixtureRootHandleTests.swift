#if DEBUG
    import Darwin
    @testable import Plainsong
    import XCTest

    final class DebugEditorFindFixtureRootHandleTests: XCTestCase {
        func testInitFailureFromValidatePathDoesNotDoubleCloseTheOpenedDescriptor() throws {
            let fileManager = FileManager.default
            let root = fileManager.temporaryDirectory.appendingPathComponent(
                "EditorFindRootHandle-\(UUID().uuidString)",
                isDirectory: true
            )
            try fileManager.createDirectory(
                at: root,
                withIntermediateDirectories: false
            )
            defer { try? fileManager.removeItem(at: root) }

            guard let status = try DebugEditorFindFixture.entryStatus(at: root) else {
                return XCTFail("missing fixtures root")
            }
            let realIdentity = DebugEditorFindFixture.identity(of: status)
            let wrongIdentity = DebugEditorFindFixture.EntryIdentity(
                device: realIdentity.device,
                inode: realIdentity.inode &+ 1
            )
            let before = descriptorsPointing(at: root)

            XCTAssertThrowsError(
                try DebugEditorFindFixtureRootHandle(
                    fixturesRoot: root,
                    expectedIdentity: wrongIdentity
                )
            ) { error in
                guard case DebugEditorFindFixture.FixtureError.unsafeFixturesRoot = error
                else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }

            XCTAssertEqual(descriptorsPointing(at: root), before)

            let canary = root.path.withCString { path in
                Darwin.open(
                    path,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            XCTAssertGreaterThanOrEqual(canary, 0)
            defer { close(canary) }

            var canaryStatus = stat()
            XCTAssertEqual(fstat(canary, &canaryStatus), 0)
            XCTAssertEqual(
                DebugEditorFindFixture.identity(of: canaryStatus),
                realIdentity
            )

            let handle = try DebugEditorFindFixtureRootHandle(
                fixturesRoot: root,
                expectedIdentity: realIdentity
            )
            _ = handle
        }

        func testCreateDirectoryPublishesAnExclusiveChildOnTheCapturedRoot() throws {
            let fileManager = FileManager.default
            let root = try makeTemporaryDirectory(named: "EditorFindRootHandle")
            defer { try? fileManager.removeItem(at: root) }
            let handle = try makeRootHandle(at: root)
            let child = root.appendingPathComponent("f9-child", isDirectory: true)

            try handle.createDirectory(at: child)

            guard let status = try DebugEditorFindFixture.entryStatus(at: child) else {
                return XCTFail("missing created workspace directory")
            }
            XCTAssertEqual(
                DebugEditorFindFixture.fileType(of: status),
                mode_t(S_IFDIR)
            )
            XCTAssertThrowsError(try handle.createDirectory(at: child)) { error in
                guard case DebugEditorFindFixture.FixtureError
                    .couldNotCreateWorkspace(EEXIST) = error
                else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }

        func testCreateDirectoryDoesNotFollowAReplacedFixturesRootPath() throws {
            let fileManager = FileManager.default
            let publishedRoot = try makeTemporaryDirectory(
                named: "EditorFindRootHandle-published"
            )
            let escapedRoot = try makeTemporaryDirectory(
                named: "EditorFindRootHandle-escaped"
            )
            defer {
                try? fileManager.removeItem(at: publishedRoot)
                try? fileManager.removeItem(at: escapedRoot)
            }
            let handle = try makeRootHandle(at: publishedRoot)
            let heldRoot = fileManager.temporaryDirectory.appendingPathComponent(
                "EditorFindRootHandle-held-\(UUID().uuidString)",
                isDirectory: true
            )
            try fileManager.moveItem(at: publishedRoot, to: heldRoot)
            try fileManager.createSymbolicLink(
                at: publishedRoot,
                withDestinationURL: escapedRoot
            )
            let childName = "f9-child"
            let publishedChild = publishedRoot.appendingPathComponent(
                childName,
                isDirectory: true
            )

            XCTAssertThrowsError(try handle.createDirectory(at: publishedChild)) { error in
                guard case DebugEditorFindFixture.FixtureError.unsafeFixturesRoot = error
                else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
            XCTAssertNil(
                try DebugEditorFindFixture.entryStatus(
                    at: escapedRoot.appendingPathComponent(childName, isDirectory: true)
                )
            )
            XCTAssertNil(
                try DebugEditorFindFixture.entryStatus(
                    at: heldRoot.appendingPathComponent(childName, isDirectory: true)
                )
            )
        }

        private func makeTemporaryDirectory(named prefix: String) throws -> URL {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(
                "\(prefix)-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: false
            )
            return url
        }

        private func makeRootHandle(at root: URL) throws -> DebugEditorFindFixtureRootHandle {
            guard let status = try DebugEditorFindFixture.entryStatus(at: root) else {
                throw DebugEditorFindFixture.FixtureError.capturedFixturesRootMissing
            }
            return try DebugEditorFindFixtureRootHandle(
                fixturesRoot: root,
                expectedIdentity: DebugEditorFindFixture.identity(of: status)
            )
        }

        private func descriptorsPointing(at url: URL) -> [Int32] {
            let expected = url.resolvingSymlinksInPath().path
            var matches: [Int32] = []
            for candidate in Int32(0) ..< 1024 {
                var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
                let result = buffer.withUnsafeMutableBufferPointer { pointer in
                    guard let baseAddress = pointer.baseAddress else {
                        return Int32(-1)
                    }
                    return Darwin.fcntl(candidate, F_GETPATH, baseAddress)
                }
                guard result == 0 else { continue }
                if String(cString: buffer) == expected {
                    matches.append(candidate)
                }
            }
            return matches
        }
    }
#endif
