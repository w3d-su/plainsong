import Foundation
import MarkdownCore
@testable import WorkspaceKit
import XCTest

// swiftlint:disable file_length

private struct WorkspaceSearchFingerprintVector {
    let text: String
    let digest: String
    let byteCount: Int
}

final class WorkspaceSearchContractTests: XCTestCase {
    func testContentFingerprintUsesStableSHA256UTF8Vectors() {
        let vectors = [
            WorkspaceSearchFingerprintVector(
                text: "",
                digest: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
                byteCount: 0
            ),
            WorkspaceSearchFingerprintVector(
                text: "hello",
                digest: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
                byteCount: 5
            ),
            WorkspaceSearchFingerprintVector(
                text: "é",
                digest: "4a99557e4033c3539de2eb65472017cad5f9557f7a0625a09f1c3f6e2ba69c4c",
                byteCount: 2
            ),
            WorkspaceSearchFingerprintVector(
                text: "e\u{301}",
                digest: "bf12767b0f2a56b2190075bae8169f656e3ce8d6357d4aff184bc6c7ea48f9f6",
                byteCount: 3
            ),
            WorkspaceSearchFingerprintVector(
                text: "你好🙂",
                digest: "b2cfe03dfa743d80691190c5800deaf375b6a7058806f88d256c0ace8bc4b51e",
                byteCount: 10
            ),
        ]

        for vector in vectors {
            let fingerprint = WorkspaceSearchContentFingerprint(text: vector.text)
            XCTAssertEqual(fingerprint.sha256Digest, vector.digest, vector.text)
            XCTAssertEqual(fingerprint.utf8ByteCount, vector.byteCount, vector.text)
        }
    }

    func testChangedExactUTF8TextChangesFingerprint() {
        let precomposed = WorkspaceSearchContentFingerprint(text: "é")
        let decomposed = WorkspaceSearchContentFingerprint(text: "e\u{301}")

        XCTAssertNotEqual(precomposed, decomposed)
        XCTAssertNotEqual(precomposed.sha256Digest, decomposed.sha256Digest)
        XCTAssertNotEqual(precomposed.utf8ByteCount, decomposed.utf8ByteCount)
    }

    func testEqualDiskAndOverlayTextProduceEqualFingerprints() async throws {
        let root = try makeTemporaryDirectory()
        let searchedText = "needle café 你好🙂"
        let diskPath = root.appendingPathComponent("disk.md").path
        let reader = FingerprintReader(contents: [diskPath: Data(searchedText.utf8)])
        let overlays = try WorkspaceSearchOverlayCollection([
            WorkspaceSearchOverlay(relativePath: "overlay.md", text: searchedText),
        ])
        let request = try makeRequest(
            root: root,
            entries: [
                entry("disk.md", identity: "disk-identity", modificationDate: .distantPast),
                entry("overlay.md", identity: "overlay-identity", modificationDate: .distantFuture),
            ],
            overlays: overlays
        )

        let results = await fileResults(in: collectEvents(
            WorkspaceSearchService(reader: reader),
            request: request
        ))

        XCTAssertEqual(results.map(\.relativePath), ["disk.md", "overlay.md"])
        guard results.count == 2 else { return }
        XCTAssertEqual(results[0].contentFingerprint, results[1].contentFingerprint)
        XCTAssertEqual(
            results[0].contentFingerprint,
            WorkspaceSearchContentFingerprint(text: searchedText)
        )
    }

    func testSnapshotMetadataChangesDoNotChangeDiskFingerprint() async throws {
        let root = try makeTemporaryDirectory()
        let path = root.appendingPathComponent("post.md").path
        let reader = FingerprintReader(contents: [path: Data("needle unchanged".utf8)])
        let firstRequest = try makeRequest(
            root: root,
            entries: [entry("post.md", identity: "old-identity", modificationDate: .distantPast)]
        )
        let secondRequest = try makeRequest(
            root: root,
            entries: [entry("post.md", identity: "new-identity", modificationDate: .distantFuture)]
        )

        let firstEvents = await collectEvents(
            WorkspaceSearchService(reader: reader),
            request: firstRequest
        )
        let secondEvents = await collectEvents(
            WorkspaceSearchService(reader: reader),
            request: secondRequest
        )
        let firstResult = try XCTUnwrap(fileResults(in: firstEvents).first)
        let secondResult = try XCTUnwrap(fileResults(in: secondEvents).first)

        XCTAssertEqual(firstResult.contentFingerprint, secondResult.contentFingerprint)
    }

    func testDiskMutationAfterSnapshotUsesNewlyReadContentAndFingerprint() async throws {
        let root = try makeTemporaryDirectory()
        let fileURL = root.appendingPathComponent("post.md")
        let oldText = "old content"
        let newText = "needle from newly read content 你好"
        try oldText.write(to: fileURL, atomically: true, encoding: .utf8)
        let metadata = try fileURL.resourceValues(forKeys: [.contentModificationDateKey])
        let request = try makeRequest(
            root: root,
            entries: [entry(
                "post.md",
                identity: "snapshot-identity",
                modificationDate: metadata.contentModificationDate
            )]
        )
        let reader = GatedFingerprintDiskReader()
        let consumer = Task {
            await collectEvents(WorkspaceSearchService(reader: reader), request: request)
        }

        await reader.waitUntilPlanningReadStarts()
        try newText.write(to: fileURL, atomically: true, encoding: .utf8)
        await reader.releasePlanningRead()
        let events = await consumer.value
        let result = try XCTUnwrap(fileResults(in: events).first)

        XCTAssertEqual(result.matches.count, 1)
        XCTAssertEqual(result.contentFingerprint, WorkspaceSearchContentFingerprint(text: newText))
        XCTAssertNotEqual(result.contentFingerprint, WorkspaceSearchContentFingerprint(text: oldText))
    }
}

extension WorkspaceSearchContractTests {
    func testOverlayPathsRejectEmptyAbsoluteAndTraversalInputs() {
        let cases: [(String, WorkspaceSearchOverlayPathError)] = [
            ("", .emptyPath),
            (".", .emptyPath),
            ("/post.md", .absolutePath),
            ("../post.md", .pathTraversal),
            ("notes/../../post.md", .pathTraversal),
        ]

        for (path, reason) in cases {
            XCTAssertThrowsError(try WorkspaceSearchOverlay(relativePath: path, text: "needle")) { error in
                XCTAssertEqual(
                    error as? WorkspaceSearchOverlayValidationError,
                    .invalidPath(path: path, reason: reason)
                )
            }
        }
    }

    func testOverlayDictionaryKeysRejectEmptyAbsoluteAndTraversalInputs() throws {
        let overlay = try WorkspaceSearchOverlay(relativePath: "post.md", text: "needle")
        let cases: [(String, WorkspaceSearchOverlayPathError)] = [
            ("", .emptyPath),
            ("/post.md", .absolutePath),
            ("../post.md", .pathTraversal),
        ]

        for (key, reason) in cases {
            XCTAssertThrowsError(try WorkspaceSearchOverlayCollection(validating: [key: overlay])) { error in
                XCTAssertEqual(
                    error as? WorkspaceSearchOverlayValidationError,
                    .invalidPath(path: key, reason: reason)
                )
            }
        }
    }

    func testOverlayDictionaryRejectsKeyPathMismatch() throws {
        let overlay = try WorkspaceSearchOverlay(relativePath: "other.md", text: "needle")

        XCTAssertThrowsError(try WorkspaceSearchOverlayCollection(validating: ["post.md": overlay])) { error in
            XCTAssertEqual(
                error as? WorkspaceSearchOverlayValidationError,
                .keyPathMismatch(key: "post.md", overlayRelativePath: "other.md")
            )
        }
    }

    func testOverlayNormalizedCollisionsAreRejectedWithoutChoosingAWinner() throws {
        let canonical = try WorkspaceSearchOverlay(relativePath: "post.md", text: "first")
        let dotted = try WorkspaceSearchOverlay(relativePath: "./post.md", text: "second")

        XCTAssertThrowsError(try WorkspaceSearchOverlayCollection([canonical, dotted])) { error in
            XCTAssertEqual(
                error as? WorkspaceSearchOverlayValidationError,
                .normalizedCollision(relativePath: "post.md")
            )
        }
        XCTAssertThrowsError(try WorkspaceSearchOverlayCollection(validating: [
            "post.md": canonical,
            "./post.md": dotted,
        ])) { error in
            XCTAssertEqual(
                error as? WorkspaceSearchOverlayValidationError,
                .normalizedCollision(relativePath: "post.md")
            )
        }
    }

    func testReorderedOverlayDictionariesProduceIdenticalCollectionsAndCollisionErrors() throws {
        let first = try WorkspaceSearchOverlay(relativePath: "first.md", text: "needle first")
        let second = try WorkspaceSearchOverlay(relativePath: "./second.md", text: "needle second")
        let forward = Dictionary(uniqueKeysWithValues: [
            ("first.md", first),
            ("./second.md", second),
        ])
        let reversed = Dictionary(uniqueKeysWithValues: [
            ("./second.md", second),
            ("first.md", first),
        ])

        XCTAssertEqual(
            try WorkspaceSearchOverlayCollection(validating: forward),
            try WorkspaceSearchOverlayCollection(validating: reversed)
        )

        let canonical = try WorkspaceSearchOverlay(relativePath: "post.md", text: "first")
        let dotted = try WorkspaceSearchOverlay(relativePath: "./post.md", text: "second")
        let collisionForward = Dictionary(uniqueKeysWithValues: [
            ("post.md", canonical),
            ("./post.md", dotted),
        ])
        let collisionReversed = Dictionary(uniqueKeysWithValues: [
            ("./post.md", dotted),
            ("post.md", canonical),
        ])

        XCTAssertEqual(
            validationError { try WorkspaceSearchOverlayCollection(validating: collisionForward) },
            validationError { try WorkspaceSearchOverlayCollection(validating: collisionReversed) }
        )
    }

    func testCanonicalOverlayStillTakesPrecedenceOverDiskContent() async throws {
        let root = try makeTemporaryDirectory()
        let path = root.appendingPathComponent("post.md").path
        let reader = FingerprintReader(contents: [path: Data("disk has no match".utf8)])
        let overlays = try WorkspaceSearchOverlayCollection([
            WorkspaceSearchOverlay(relativePath: "./post.md", text: "needle from overlay"),
        ])
        let request = try makeRequest(root: root, entries: [entry("post.md")], overlays: overlays)

        let events = await collectEvents(
            WorkspaceSearchService(reader: reader),
            request: request
        )
        let result = try XCTUnwrap(fileResults(in: events).first)
        let diskReadCount = await reader.readCount(for: path)

        XCTAssertEqual(result.contentFingerprint, WorkspaceSearchContentFingerprint(text: "needle from overlay"))
        XCTAssertEqual(diskReadCount, 0)
    }

    func testSyntheticCanonicalEquivalentSnapshotPathsRemainDistinctCandidates() async throws {
        let root = try makeTemporaryDirectory()
        let nfcPath = "caf\u{00E9}.md"
        let nfdPath = "cafe\u{0301}.md"
        let request = try makeRequest(
            root: root,
            entries: [entry(nfcPath), entry(nfdPath)],
            limits: WorkspaceSearchLimits(maximumIgnoreFiles: 0)
        )

        let plan = try await WorkspaceSearchCandidatePlanner.makePlan(
            request: request,
            reader: MissingContractReader()
        )
        let candidatePaths = plan.items.compactMap { item -> String? in
            guard case let .candidate(_, candidate) = item else { return nil }
            return candidate.relativePath
        }
        let expectedPaths = [nfcPath, nfdPath].sorted {
            WorkspacePathByteKey($0) < WorkspacePathByteKey($1)
        }

        XCTAssertEqual(plan.candidateFileCount, 2)
        XCTAssertEqual(
            candidatePaths.map { WorkspacePathByteKey($0).bytes },
            expectedPaths.map { WorkspacePathByteKey($0).bytes }
        )
    }

    func testCanonicalEquivalentOverlayPathsUseDistinctByteKeys() throws {
        let nfcPath = "caf\u{00E9}.md"
        let nfdPath = "cafe\u{0301}.md"
        let overlays = try WorkspaceSearchOverlayCollection([
            WorkspaceSearchOverlay(relativePath: nfcPath, text: "NFC overlay"),
            WorkspaceSearchOverlay(relativePath: nfdPath, text: "NFD overlay"),
        ])
        let expectedPaths = [nfcPath, nfdPath].sorted {
            WorkspacePathByteKey($0) < WorkspacePathByteKey($1)
        }

        XCTAssertEqual(
            overlays.overlays.map { WorkspacePathByteKey($0.relativePath).bytes },
            expectedPaths.map { WorkspacePathByteKey($0).bytes }
        )
        XCTAssertEqual(overlays[nfcPath]?.text, "NFC overlay")
        XCTAssertEqual(overlays[nfdPath]?.text, "NFD overlay")
    }

    func testLegacyOverlayKeyRequiresByteExactValuePath() throws {
        let nfcPath = "caf\u{00E9}.md"
        let nfdPath = "cafe\u{0301}.md"
        let overlay = try WorkspaceSearchOverlay(relativePath: nfcPath, text: "needle")

        XCTAssertThrowsError(
            try WorkspaceSearchOverlayCollection(validating: [nfdPath: overlay])
        ) { error in
            guard case let .keyPathMismatch(key, overlayRelativePath) =
                error as? WorkspaceSearchOverlayValidationError
            else {
                return XCTFail("expected a byte-exact key/path mismatch, got \(error)")
            }
            XCTAssertEqual(WorkspacePathByteKey(key).bytes, WorkspacePathByteKey(nfdPath).bytes)
            XCTAssertEqual(
                WorkspacePathByteKey(overlayRelativePath).bytes,
                WorkspacePathByteKey(nfcPath).bytes
            )
        }
    }

    func testSyntheticCandidateDoesNotBorrowCanonicalEquivalentOverlay() async throws {
        let root = try makeTemporaryDirectory()
        let nfcPath = "caf\u{00E9}.md"
        let nfdPath = "cafe\u{0301}.md"

        for (candidatePath, overlayPath) in [(nfcPath, nfdPath), (nfdPath, nfcPath)] {
            let overlays = try WorkspaceSearchOverlayCollection([
                WorkspaceSearchOverlay(relativePath: overlayPath, text: "wrong overlay"),
            ])
            let request = try makeRequest(
                root: root,
                entries: [entry(candidatePath)],
                overlays: overlays,
                limits: WorkspaceSearchLimits(maximumIgnoreFiles: 0)
            )
            let plan = try await WorkspaceSearchCandidatePlanner.makePlan(
                request: request,
                reader: MissingContractReader()
            )
            let candidates = plan.items.compactMap { item -> WorkspaceSearchCandidate? in
                guard case let .candidate(_, candidate) = item else { return nil }
                return candidate
            }

            XCTAssertEqual(candidates.count, 1)
            XCTAssertNil(candidates.first?.overlay)
        }
    }

    func testNestedIgnoreRuleDoesNotCrossCanonicalEquivalentDirectoryBytes() async throws {
        let root = try makeTemporaryDirectory()
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let nfcDirectory = "caf\u{00E9}"
        let nfdDirectory = "cafe\u{0301}"
        let nfcCandidate = "\(nfcDirectory)/post.md"
        let nfdCandidate = "\(nfdDirectory)/post.md"
        let reader = ByteExactIgnoreReader(contents: [
            WorkspacePathByteKey("\(nfcDirectory)/.gitignore"): Data("post.md\n".utf8),
        ])

        let policy = try await WorkspaceSearchIgnorePolicy.load(
            rootAuthority: authority,
            candidatePaths: [nfcCandidate, nfdCandidate],
            limits: WorkspaceSearchLimits(),
            reader: reader
        )

        XCTAssertTrue(policy.isIgnored(relativePath: nfcCandidate))
        XCTAssertFalse(policy.isIgnored(relativePath: nfdCandidate))
    }

    private func makeRequest(
        root: URL,
        entries: [WorkspaceFileSnapshot.Entry],
        overlays: WorkspaceSearchOverlayCollection = .empty,
        limits: WorkspaceSearchLimits = .init()
    ) throws -> WorkspaceSearchRequest {
        try WorkspaceSearchRequest(
            rootAuthority: WorkspaceFileSystemRootAuthority(rootURL: root),
            rootIdentity: "fingerprint-test-root",
            snapshot: WorkspaceFileSnapshot(entries: entries),
            workspaceGeneration: 3,
            queryGeneration: 5,
            query: TextSearchQuery(pattern: "needle"),
            dirtyOverlays: overlays,
            limits: limits
        )
    }

    private func entry(
        _ relativePath: String,
        identity: String? = nil,
        modificationDate: Date? = nil
    ) -> WorkspaceFileSnapshot.Entry {
        WorkspaceFileSnapshot.Entry(
            relativePath: relativePath,
            kind: .markdown,
            identity: identity ?? relativePath,
            contentModificationDate: modificationDate
        )
    }

    private func collectEvents(
        _ service: WorkspaceSearchService,
        request: WorkspaceSearchRequest
    ) async -> [WorkspaceSearchEvent] {
        var events: [WorkspaceSearchEvent] = []
        for await event in service.events(for: request) {
            events.append(event)
        }
        return events
    }

    private func fileResults(in events: [WorkspaceSearchEvent]) -> [WorkspaceSearchFileResult] {
        events.compactMap { event in
            guard case let .fileResult(_, result) = event else { return nil }
            return result
        }
    }

    private func validationError(
        _ body: () throws -> some Any
    ) -> WorkspaceSearchOverlayValidationError? {
        do {
            _ = try body()
            XCTFail("Expected overlay validation to fail")
            return nil
        } catch {
            return error as? WorkspaceSearchOverlayValidationError
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceSearchFingerprintAndOverlayTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return try WorkspaceFileSystemRootAuthority(rootURL: url).canonicalRootURL
    }
}

private actor FingerprintReader: SyntheticWorkspaceSearchFileReading {
    private let contents: [String: Data]
    private var readCounts: [String: Int] = [:]

    init(contents: [String: Data]) {
        self.contents = contents
    }

    func readFile(at url: URL, maximumByteCount: Int) async throws -> Data {
        readCounts[url.path, default: 0] += 1
        guard let data = contents[url.path] else {
            throw WorkspaceSearchFileReadError.disappeared
        }
        return Data(data.prefix(maximumByteCount))
    }

    func readCount(for path: String) -> Int {
        readCounts[path, default: 0]
    }
}

private struct ByteExactIgnoreReader: SyntheticWorkspaceSearchFileReading {
    let contents: [WorkspacePathByteKey: Data]

    func readFile(at _: URL, maximumByteCount _: Int) async throws -> Data {
        throw WorkspaceSearchFileReadError.disappeared
    }

    func readFile(
        at location: WorkspaceFileSystemLocation,
        maximumByteCount: Int
    ) async throws -> Data {
        guard let data = contents[WorkspacePathByteKey(location.relativePath)] else {
            throw WorkspaceSearchFileReadError.disappeared
        }
        return Data(data.prefix(maximumByteCount))
    }
}

private actor GatedFingerprintDiskReader: WorkspaceSearchFileReading {
    private var didStartPlanningRead = false
    private var planningReadWaiters: [CheckedContinuation<Void, Never>] = []
    private var planningReadContinuation: CheckedContinuation<Void, Never>?

    func readFile(at url: URL, maximumByteCount: Int) async throws -> Data {
        if url.lastPathComponent == ".gitignore" {
            didStartPlanningRead = true
            let waiters = planningReadWaiters
            planningReadWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
            await withCheckedContinuation { continuation in
                planningReadContinuation = continuation
            }
            throw WorkspaceSearchFileReadError.disappeared
        }
        if url.lastPathComponent == ".ignore" {
            throw WorkspaceSearchFileReadError.disappeared
        }

        let data = try Data(contentsOf: url)
        return Data(data.prefix(maximumByteCount))
    }

    func waitUntilPlanningReadStarts() async {
        if didStartPlanningRead { return }
        await withCheckedContinuation { continuation in
            planningReadWaiters.append(continuation)
        }
    }

    func releasePlanningRead() {
        planningReadContinuation?.resume()
        planningReadContinuation = nil
    }
}
