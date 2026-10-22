@testable import WorkspaceKit
import XCTest

final class WorkspaceCoreAdapterTests: XCTestCase {
    func testAdapterRoundTripsMutationExpectationForEveryNode() {
        let readme = expectation(device: 10, inode: 1, kind: .regularFile)
        let posts = expectation(device: 10, inode: 2, kind: .directory)
        let nested = expectation(device: 10, inode: 3, kind: .regularFile)
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        let tree = WorkspaceFileTree.reconcile(
            previous: nil,
            snapshot: WorkspaceFileSnapshot(entries: [
                WorkspaceFileSnapshot.Entry(
                    relativePath: "README.md",
                    kind: .markdown,
                    identity: "readme",
                    contentModificationDate: modified,
                    mutationExpectation: readme
                ),
                WorkspaceFileSnapshot.Entry(
                    relativePath: "posts",
                    kind: .directory,
                    identity: "posts",
                    contentModificationDate: nil,
                    mutationExpectation: posts
                ),
                WorkspaceFileSnapshot.Entry(
                    relativePath: "posts/note.md",
                    kind: .markdown,
                    identity: "note",
                    contentModificationDate: nil,
                    mutationExpectation: nested
                ),
            ]),
            options: .init(showAllFiles: true)
        )

        XCTAssertNil(tree.root.mutationExpectation)
        XCTAssertEqual(tree.node(id: "readme")?.mutationExpectation, readme)
        XCTAssertEqual(tree.node(id: "readme")?.contentModificationDate, modified)
        XCTAssertEqual(tree.node(id: "posts")?.mutationExpectation, posts)
        XCTAssertEqual(tree.node(id: "note")?.mutationExpectation, nested)
    }

    func testDuplicateIdentityKeepsEachPathExpectation() {
        let first = expectation(device: 4, inode: 1, kind: .regularFile)
        let second = expectation(device: 4, inode: 2, kind: .regularFile)
        let tree = WorkspaceFileTree.reconcile(
            previous: nil,
            snapshot: WorkspaceFileSnapshot(entries: [
                entry("first.md", identity: "shared-inode", expectation: first),
                entry("second.md", identity: "shared-inode", expectation: second),
            ]),
            options: .init(showAllFiles: true)
        )

        XCTAssertEqual(tree.root.children.map(\.relativePath), ["first.md", "second.md"])
        XCTAssertEqual(tree.root.children.map(\.mutationExpectation), [first, second])
        XCTAssertEqual(Set(tree.root.children.map(\.id)).count, 2)
    }

    func testCanonicalSpellingsKeepSeparateExpectations() {
        let nfcDirectory = "caf\u{00E9}"
        let nfdDirectory = "cafe\u{0301}"
        let nfcExpectation = expectation(device: 8, inode: 1, kind: .directory)
        let nfdExpectation = expectation(device: 8, inode: 2, kind: .directory)
        let nfcChild = expectation(device: 8, inode: 3, kind: .regularFile)
        let nfdChild = expectation(device: 8, inode: 4, kind: .regularFile)
        let tree = WorkspaceFileTree.reconcile(
            previous: nil,
            snapshot: WorkspaceFileSnapshot(entries: [
                entry(nfcDirectory, kind: .directory, identity: "nfc-directory", expectation: nfcExpectation),
                entry(
                    "\(nfcDirectory)/nfc.md",
                    identity: "nfc-child",
                    expectation: nfcChild
                ),
                entry(nfdDirectory, kind: .directory, identity: "nfd-directory", expectation: nfdExpectation),
                entry(
                    "\(nfdDirectory)/nfd.md",
                    identity: "nfd-child",
                    expectation: nfdChild
                ),
            ]),
            options: .init(showAllFiles: true)
        )

        XCTAssertEqual(tree.node(id: "nfc-directory")?.mutationExpectation, nfcExpectation)
        XCTAssertEqual(tree.node(id: "nfd-directory")?.mutationExpectation, nfdExpectation)
        XCTAssertEqual(tree.node(id: "nfc-child")?.mutationExpectation, nfcChild)
        XCTAssertEqual(tree.node(id: "nfd-child")?.mutationExpectation, nfdChild)
        XCTAssertEqual(tree.root.children.map(\.id), ["nfd-directory", "nfc-directory"])
    }

    private func expectation(
        device: UInt64,
        inode: UInt64,
        kind: WorkspaceFileSystemItemKind
    ) -> WorkspaceItemMutationExpectation {
        WorkspaceItemMutationExpectation(
            identity: WorkspaceFileSystemIdentity(device: device, inode: inode),
            kind: kind
        )
    }

    private func entry(
        _ relativePath: String,
        kind: WorkspaceFileKind = .markdown,
        identity: String,
        expectation: WorkspaceItemMutationExpectation
    ) -> WorkspaceFileSnapshot.Entry {
        WorkspaceFileSnapshot.Entry(
            relativePath: relativePath,
            kind: kind,
            identity: identity,
            contentModificationDate: nil,
            mutationExpectation: expectation
        )
    }
}
