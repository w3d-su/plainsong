import Foundation
import MarkdownCore
import WorkspaceKit
import XCTest

// Fixtures for the ignore-policy, progress-coalescing, and case-policy probes. Split from
// `WorkspaceSearchPerformanceFixtures.swift` to keep each file near the ~400-line guidance
// in agent.md §17.10.

extension WorkspaceSearchPerformanceTests {
    /// One matching file plus a `.gitignore` that names it and is deliberately far over the
    /// 64 KiB ignore ceiling. The rule is placed first so an implementation that parsed a
    /// truncated prefix would still see it — only outright rejection keeps the file searchable.
    func makeOversizedIgnoreFixture() async throws -> IgnoreFixture {
        try await makeIgnoreFixture(
            prefix: "WS4BOversizedIgnore",
            ignoreFileByteCount: Self.oversizedIgnoreFileByteCount
        )
    }

    /// Control: the same rule, comfortably under the ceiling, so it must be honored.
    func makeUnderCeilingIgnoreFixture() async throws -> IgnoreFixture {
        try await makeIgnoreFixture(prefix: "WS4BUnderCeilingIgnore", ignoreFileByteCount: nil)
    }

    private func makeIgnoreFixture(
        prefix: String,
        ignoreFileByteCount: Int?
    ) async throws -> IgnoreFixture {
        let root = try makeTemporaryDirectory(prefix: prefix)
        let ignoredName = "ignored-post.md"
        try Data(Self.makeBody(index: 0, includesToken: true).utf8)
            .write(to: root.appendingPathComponent(ignoredName), options: .atomic)

        var ignore = "\(ignoredName)\n"
        if let ignoreFileByteCount {
            // Pad with comment lines, which the rule parser ignores, so only the file's size
            // distinguishes this from the control fixture.
            let padding = "# padding to exceed the ignore-file ceiling\n"
            while ignore.utf8.count + padding.utf8.count <= ignoreFileByteCount {
                ignore += padding
            }
            ignore += String(repeating: "#", count: ignoreFileByteCount - ignore.utf8.count)
            XCTAssertEqual(ignore.utf8.count, ignoreFileByteCount)
            XCTAssertGreaterThan(ignore.utf8.count, Self.expectedMaximumIgnoreFileSizeBytes)
        } else {
            XCTAssertLessThanOrEqual(ignore.utf8.count, Self.expectedMaximumIgnoreFileSizeBytes)
        }
        try Data(ignore.utf8).write(to: root.appendingPathComponent(".gitignore"), options: .atomic)

        let capture = try await WorkspaceDirectoryScanner().snapshotCapture(root: root)
        return IgnoreFixture(
            rootURL: root,
            capture: capture,
            ignoredRelativePath: ignoredName
        )
    }

    /// 250 files, of which every fourth matches. The count matters more than the content: it is
    /// above the 100-event progress cap and not divisible by it, so the coalescing stride is
    /// exercised for real.
    func makeProgressStrideFixture() async throws -> BulkWorkspaceFixture {
        let root = try makeTemporaryDirectory(prefix: "WS4BProgressStride")
        var orderedRelativePaths: [String] = []
        var matchingRelativePaths: [String] = []
        var totalByteCount = 0
        var matchingBody: String?

        for index in 0 ..< Self.progressStrideFileCount {
            let includesToken = index.isMultiple(of: Self.bulkMatchingStride)
            let name = String(format: "post-%04d.md", index)
            let body = Self.makeBody(index: index, includesToken: includesToken)
            try Data(body.utf8).write(to: root.appendingPathComponent(name), options: .atomic)
            orderedRelativePaths.append(name)
            totalByteCount += body.utf8.count
            if includesToken {
                matchingRelativePaths.append(name)
                matchingBody = matchingBody ?? body
            }
        }

        let capture = try await WorkspaceDirectoryScanner().snapshotCapture(root: root)
        let sampleMatchingBody = try XCTUnwrap(matchingBody)

        return BulkWorkspaceFixture(
            rootURL: root,
            capture: capture,
            orderedRelativePaths: orderedRelativePaths,
            matchingRelativePaths: matchingRelativePaths,
            totalByteCount: totalByteCount,
            expectedMatchRanges: Self.independentTokenRanges(in: sampleMatchingBody)
        )
    }

    func makeSmartCaseFixture() async throws -> SingleFileFixture {
        let root = try makeTemporaryDirectory(prefix: "WS4BSmartCase")
        let body = Self.makeSmartCaseBody()
        try Data(body.utf8).write(to: root.appendingPathComponent("smart-case.md"), options: .atomic)

        let capture = try await WorkspaceDirectoryScanner().snapshotCapture(root: root)
        let range = try XCTUnwrap(Self.independentTokenRanges(in: body).first)

        return SingleFileFixture(
            rootURL: root,
            capture: capture,
            relativePath: "smart-case.md",
            byteCount: body.utf8.count,
            expectedMatchRange: range,
            expectedLine: Self.lineNumber(ofUTF16Location: range.location, in: body)
        )
    }

    func makeAdmittedCJKFileFixture() async throws -> SingleFileFixture {
        let root = try makeTemporaryDirectory(prefix: "WS4BAdmittedCJK")
        let body = Self.makeExactlyAdmittedCJKBody()
        XCTAssertEqual(body.utf8.count, Self.admittedFileByteCount)
        try Data(body.utf8).write(to: root.appendingPathComponent("admitted-cjk.md"), options: .atomic)

        let capture = try await WorkspaceDirectoryScanner().snapshotCapture(root: root)
        let ranges = Self.independentRanges(of: Self.cjkCasedOccurrence, in: body)
        XCTAssertEqual(ranges.count, 1)
        // The lower-case pattern must not occur literally, or a `.sensitive` control would match
        // and the probe would stop discriminating between backends.
        XCTAssertTrue(Self.independentRanges(of: Self.cjkCasedPattern, in: body).isEmpty)
        let range = try XCTUnwrap(ranges.first)

        return SingleFileFixture(
            rootURL: root,
            capture: capture,
            relativePath: "admitted-cjk.md",
            byteCount: body.utf8.count,
            expectedMatchRange: range,
            expectedLine: Self.lineNumber(ofUTF16Location: range.location, in: body)
        )
    }
}
