import Darwin
import Foundation
@testable import WorkspaceKit
import XCTest

/// Regressions for the exact-literal-byte-spelling contract of `WorkspaceFileSystemLocation`
/// and `WorkspaceFileSystemRootAuthority`: retained NFC-composed Unicode paths must round-trip
/// through the "exact location/recovery" API surface without being silently decomposed to NFD.
final class WorkspaceLiteralSpellingTests: XCTestCase {
    func testLiteralLocationAndRootCaptureRejectNonFileAndNULURLs() throws {
        let remoteURL = try XCTUnwrap(URL(string: "https://example.com/tmp/secret.md"))
        let nulURL = try XCTUnwrap(URL(string: "file:///tmp/%00/secret.md"))

        // Raw path extraction must not turn a non-file URL into a local authority, and a NUL
        // must be rejected before C-string conversion can truncate `/tmp/\0/secret.md` to
        // `/tmp`. Both checks are part of the literal-spelling path, not a Foundation
        // canonicalization fallback.
        XCTAssertThrowsError(try WorkspaceFileSystemLocation(fileURL: remoteURL)) { error in
            guard case .absolutePath = error as? WorkspaceRootContainmentError else {
                return XCTFail("expected an absolute-path rejection, got \(error)")
            }
        }
        XCTAssertThrowsError(try WorkspaceFileSystemRootAuthority(rootURL: remoteURL)) { error in
            guard case .absolutePath = error as? WorkspaceRootContainmentError else {
                return XCTFail("expected an absolute-path rejection, got \(error)")
            }
        }
        XCTAssertThrowsError(try WorkspaceFileSystemLocation(fileURL: nulURL)) { error in
            guard case .traversal = error as? WorkspaceRootContainmentError else {
                return XCTFail("expected a traversal rejection, got \(error)")
            }
        }
        XCTAssertThrowsError(try WorkspaceFileSystemRootAuthority(rootURL: nulURL)) { error in
            guard case .traversal = error as? WorkspaceRootContainmentError else {
                return XCTFail("expected a traversal rejection, got \(error)")
            }
        }

        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        XCTAssertThrowsError(try authority.relativePath(forFileURL: remoteURL)) { error in
            guard case .absolutePath = error as? WorkspaceRootContainmentError else {
                return XCTFail("expected an absolute-path rejection, got \(error)")
            }
        }
    }

    func testRelativePathForFileURLRoundTripsRetainedNFCSpellingExactly() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let nfcPath = "caf\u{00E9}.md"
        let retained = try authority.location(relativePath: nfcPath)

        // Feeding the retained, lexically constructed fileURL back through
        // relativePath(forFileURL:) must reproduce the exact NFC bytes. Routing through
        // `standardizedFileURL` before extracting the path silently decomposes precomposed
        // Unicode (NFC) into decomposed form (NFD) via CoreFoundation's file-system
        // representation bridging, which would corrupt this round trip.
        let roundTrippedRelativePath = try authority.relativePath(forFileURL: retained.fileURL)

        XCTAssertEqual(
            roundTrippedRelativePath.utf8.map(\.self),
            nfcPath.utf8.map(\.self)
        )
        let roundTripped = try authority.location(relativePath: roundTrippedRelativePath)
        XCTAssertEqual(roundTripped, retained)
    }

    func testRelativePathForFileURLDistinguishesNFDFromRetainedNFC() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let nfcRetained = try authority.location(relativePath: "caf\u{00E9}.md")
        let nfdPath = "cafe\u{0301}.md"
        let nfdCandidate = try authority.location(relativePath: nfdPath)

        // An actually-NFD-spelled candidate must not be silently treated as the retained
        // NFC location: it remains a distinct, non-exact spelling.
        XCTAssertNotEqual(nfdCandidate, nfcRetained)

        let nfdRoundTripped = try authority.relativePath(forFileURL: nfdCandidate.fileURL)
        XCTAssertEqual(nfdRoundTripped.utf8.map(\.self), nfdPath.utf8.map(\.self))
        XCTAssertNotEqual(
            try authority.location(relativePath: nfdRoundTripped),
            nfcRetained
        )
    }

    func testLocationFileURLInitRoundTripsRetainedNFCSpellingExactly() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let nfcPath = "caf\u{00E9}.md"
        let retained = try authority.location(relativePath: nfcPath)

        // `WorkspaceFileSystemLocation(fileURL:)` must not corrupt an already-exact retained
        // spelling by routing it through `standardizedFileURL` before reading
        // `lastPathComponent`.
        let roundTripped = try WorkspaceFileSystemLocation(fileURL: retained.fileURL)

        XCTAssertEqual(
            roundTripped.relativePath.utf8.map(\.self),
            nfcPath.utf8.map(\.self)
        )
        XCTAssertEqual(roundTripped, retained)
    }

    func testMissingTargetInspectionPreservesExactNFCSpelling() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let nfcLocation = try authority.location(relativePath: "caf\u{00E9}.md")

        // The leaf never existed on disk, so `inspectFileTarget` retains it verbatim via
        // `missingFileTargetInspection`. Combining the descriptor-derived parent with that
        // leaf via `appendingPathComponent` would decompose the NFC leaf to NFD before this
        // inspection's `canonicalLocation` is computed, spuriously failing the exact-location
        // equality callers (Save Copy's missing-source recovery) rely on.
        let inspection = try WorkspaceNoFollowFileInspector.inspectFileTarget(at: nfcLocation)

        XCTAssertEqual(inspection.state, .missing)
        XCTAssertEqual(inspection.canonicalLocation, nfcLocation)
        XCTAssertEqual(
            inspection.canonicalLocation.relativePath.utf8.map(\.self),
            nfcLocation.relativePath.utf8.map(\.self)
        )
    }

    func testExistingTargetInspectionPreservesExactNFCSpelling() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let nfcLocation = try authority.location(relativePath: "caf\u{00E9}.md")
        // `WorkspaceNoFollowFileWriter` creates the file through raw UTF-8 bytes
        // (`String.withCString`), not Foundation's `Data`/`String.write(to:)`, which would
        // decompose the NFC leaf to NFD via file-system-representation bridging before the
        // file ever reached disk. This matches how the app actually writes documents, so the
        // on-disk leaf is genuinely NFC-spelled and `canonicalLeafName`'s exact-match branch
        // (not its case/normalization-insensitive fallback) is what this test exercises.
        let outcome = WorkspaceNoFollowFileWriter.write(
            text: "content",
            to: nfcLocation,
            expecting: .missing
        )
        guard case .committedAndDurable = outcome else {
            return XCTFail("expected the NFC-spelled file to be created durably")
        }

        let inspection = try WorkspaceNoFollowFileInspector.inspectFileTarget(at: nfcLocation)

        guard case .regular = inspection.state else {
            return XCTFail("expected a regular file state")
        }
        XCTAssertEqual(inspection.canonicalLocation, nfcLocation)
        XCTAssertEqual(
            inspection.canonicalLocation.relativePath.utf8.map(\.self),
            nfcLocation.relativePath.utf8.map(\.self)
        )
    }

    func testCanonicalizedLocationPreservesNFCInRootParentAndLeaf() throws {
        let temporaryRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let nfcRootPath = temporaryRoot.path(percentEncoded: false) + "/r\u{00E9}sum\u{00E9}"
        let createResult = nfcRootPath.withCString { Darwin.mkdir($0, 0o755) }
        XCTAssertEqual(createResult, 0, "test setup must create the NFC-spelled root literally")

        // This intentionally builds the root URL from percent-encoded UTF-8 bytes. A normal
        // `URL(fileURLWithPath:)` construction can decompose NFC before the descriptor capture
        // starts, which would leave the canonicalization path below untested.
        let nfcRootURL = WorkspaceLiteralFileURL.fileURL(path: nfcRootPath, isDirectory: true)
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: nfcRootURL)
        let expectedRelativePath = "d\u{00E9}j\u{00E0}/caf\u{00E9}.md"
        let nfcParentPath = nfcRootPath + "/d\u{00E9}j\u{00E0}"
        let createParentResult = nfcParentPath.withCString { Darwin.mkdir($0, 0o755) }
        XCTAssertEqual(createParentResult, 0, "test setup must create the NFC-spelled parent literally")
        let expected = try authority.location(relativePath: expectedRelativePath)
        let outcome = WorkspaceNoFollowFileWriter.write(
            text: "content",
            to: expected,
            expecting: .missing
        )
        guard case .committedAndDurable = outcome else {
            return XCTFail("expected the NFC-spelled nested file to be created durably")
        }

        // This exercises the descriptor URL -> relativePath -> authority.location round trip.
        // Every component (root, parent, and leaf) must retain its literal NFC UTF-8 spelling.
        let canonicalized = try authority.canonicalizedLocation(forFileURL: expected.fileURL)

        XCTAssertEqual(canonicalized, expected)
        XCTAssertEqual(
            canonicalized.relativePath.utf8.map(\.self),
            expectedRelativePath.utf8.map(\.self)
        )
        XCTAssertEqual(
            canonicalized.fileURL.path(percentEncoded: false).utf8.map(\.self),
            expected.fileURL.path(percentEncoded: false).utf8.map(\.self)
        )
    }

    func testDescriptorParentContainmentRejectsNFDParentUnderNFCRoot() throws {
        let temporaryRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let nfcRootPath = temporaryRoot.path(percentEncoded: false) + "/caf\u{00E9}"
        XCTAssertEqual(
            nfcRootPath.withCString { Darwin.mkdir($0, 0o755) },
            0,
            "test setup must create the NFC-spelled root literally"
        )
        let authority = try WorkspaceFileSystemRootAuthority(
            rootURL: WorkspaceLiteralFileURL.fileURL(path: nfcRootPath, isDirectory: true)
        )
        let canonicalRootPath = WorkspaceRootContainment.normalizedDirectoryPath(
            authority.canonicalRootURL.path(percentEncoded: false)
        )
        XCTAssertTrue(
            canonicalRootPath.utf8.suffix("caf\u{00E9}".utf8.count)
                .elementsEqual("caf\u{00E9}".utf8)
        )
        let canonicalRootParent = try WorkspaceLiteralFileURL.parentPath(of: canonicalRootPath)

        let nfdParentURL = WorkspaceLiteralFileURL.fileURL(
            path: canonicalRootParent + "/cafe\u{0301}/nested",
            isDirectory: true
        )
        XCTAssertThrowsError(
            try authority.relativePath(
                forCanonicalDescriptorParentURL: nfdParentURL,
                leaf: "post.md"
            )
        ) { error in
            XCTAssertEqual(error as? WorkspaceRootContainmentError, .fileOutsideRoot)
        }
    }

    func testDirectoryScannerRejectsNFDChildUnderNFCRoot() {
        let nfcRoot = WorkspaceLiteralFileURL.fileURL(
            path: "/tmp/WorkspaceLiteralSpelling/caf\u{00E9}",
            isDirectory: true
        )
        let nfdChild = WorkspaceLiteralFileURL.fileURL(
            path: "/tmp/WorkspaceLiteralSpelling/cafe\u{0301}/post.md",
            isDirectory: false
        )

        XCTAssertEqual(
            WorkspaceDirectoryScanner.relativePath(
                for: nfdChild,
                root: nfcRoot,
                preservesLiteralEntrySpelling: true
            ),
            ""
        )
    }
}

extension WorkspaceLiteralSpellingTests {
    func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceLiteralSpellingTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
