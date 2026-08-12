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

        private func descriptorsPointing(at url: URL) -> [Int32] {
            let expected = url.resolvingSymlinksInPath().path
            var matches: [Int32] = []
            for candidate in Int32(0) ..< 1024 {
                var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
                let result = buffer.withUnsafeMutableBufferPointer { pointer in
                    fcntl(candidate, F_GETPATH, pointer.baseAddress)
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
