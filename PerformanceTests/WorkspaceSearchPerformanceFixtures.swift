import Foundation
import MarkdownCore
import WorkspaceKit
import XCTest

// Fixtures for the WS4B workspace-search performance gates: on-disk workspace shapes and
// the builders that create them. Split out of `WorkspaceSearchPerformanceTests.swift` to
// keep each file near the ~400-line guidance in agent.md §17.10.

// MARK: - Fixtures

struct BulkWorkspaceFixture {
    let rootURL: URL
    let capture: WorkspaceDirectorySnapshotCapture
    let orderedRelativePaths: [String]
    let matchingRelativePaths: [String]
    let totalByteCount: Int
    let expectedMatchRanges: [NSRange]
}

struct SingleFileFixture {
    let rootURL: URL
    let capture: WorkspaceDirectorySnapshotCapture
    let relativePath: String
    let byteCount: Int
    let expectedMatchRange: NSRange
    let expectedLine: Int
}

struct IgnoreFixture {
    let rootURL: URL
    let capture: WorkspaceDirectorySnapshotCapture
    let ignoredRelativePath: String
}

struct GlobalCapFixture {
    let rootURL: URL
    let capture: WorkspaceDirectorySnapshotCapture
    let orderedRelativePaths: [String]
    let totalByteCount: Int
}

struct DenseWholeWordFixture {
    let rootURL: URL
    let capture: WorkspaceDirectorySnapshotCapture
    let relativePath: String
    let byteCount: Int
    let pattern: String
}

/// Two whole-word rejection shapes at the admission cap. `suffixRejected` is ordinary ASCII
/// prose whose every literal hit is rejected by a trailing word character; `composedPeriodic`
/// is the adversarial non-ASCII periodic text whose overlapping candidates force composed
/// boundary work — the shape that motivated the 512 KiB admission cap.
enum DenseWholeWordShape: String, CaseIterable {
    case suffixRejected = "ascii-suffix"
    case composedPeriodic = "unicode-periodic"

    /// Frozen from evidence recorded in `docs/perf-log.md`, which is the authority. At the
    /// measured commit the slowest Debug medians were 45.635 ms (`ascii-suffix`, ~4.4x headroom)
    /// and 1027.955 ms (`composedPeriodic`, ~2.4x). The composed-periodic shape is the documented
    /// worst case at the admission cap — ~660-702 ms in Release at exactly 512 KiB — which is why
    /// a 1 MiB admission cap was rejected.
    var budgetMilliseconds: Double {
        switch self {
        case .suffixRejected:
            200
        case .composedPeriodic:
            2500
        }
    }
}

extension WorkspaceSearchPerformanceTests {
    func makeBulkWorkspaceFixture() async throws -> BulkWorkspaceFixture {
        let root = try makeTemporaryDirectory(prefix: "WS4BBulkWorkspace")
        let filesPerSection = Self.bulkFileCount / Self.bulkSectionCount
        var orderedRelativePaths: [String] = []
        var matchingRelativePaths: [String] = []
        var totalByteCount = 0
        var matchingBody: String?

        for section in 0 ..< Self.bulkSectionCount {
            let directoryName = String(format: "section-%02d", section)
            let directoryURL = root.appendingPathComponent(directoryName, isDirectory: true)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: false)

            for offset in 0 ..< filesPerSection {
                let index = section * filesPerSection + offset
                let includesToken = index.isMultiple(of: Self.bulkMatchingStride)
                let fileExtension = index.isMultiple(of: 5) ? "mdx" : "md"
                let name = String(format: "post-%04d.%@", index, fileExtension)
                let relativePath = "\(directoryName)/\(name)"
                let body = Self.makeBody(index: index, includesToken: includesToken)
                try Data(body.utf8).write(to: directoryURL.appendingPathComponent(name), options: .atomic)

                orderedRelativePaths.append(relativePath)
                totalByteCount += body.utf8.count
                if includesToken {
                    matchingRelativePaths.append(relativePath)
                    matchingBody = matchingBody ?? body
                }
            }
        }

        let capture = try await WorkspaceDirectoryScanner().snapshotCapture(root: root)
        let sampleMatchingBody = try XCTUnwrap(matchingBody)
        let expectedMatchRanges = Self.independentTokenRanges(in: sampleMatchingBody)
        XCTAssertEqual(expectedMatchRanges.count, Self.matchesPerMatchingFile)

        return BulkWorkspaceFixture(
            rootURL: root,
            capture: capture,
            orderedRelativePaths: orderedRelativePaths,
            matchingRelativePaths: matchingRelativePaths,
            totalByteCount: totalByteCount,
            expectedMatchRanges: expectedMatchRanges
        )
    }

    func makeGlobalCapFixture() async throws -> GlobalCapFixture {
        let root = try makeTemporaryDirectory(prefix: "WS4BGlobalMatchCap")
        var orderedRelativePaths: [String] = []
        var totalByteCount = 0

        // One occurrence more than the per-file ceiling, so every file is also per-file
        // truncated and the global ceiling is reached exactly on a file boundary.
        let body = (0 ..< Self.globalCapOccurrencesPerFile)
            .map { "line \($0) \(Self.token)\n" }
            .joined()

        for index in 0 ..< Self.globalCapFileCount {
            let name = String(format: "cap-%02d.md", index)
            try Data(body.utf8).write(to: root.appendingPathComponent(name), options: .atomic)
            orderedRelativePaths.append(name)
            totalByteCount += body.utf8.count
        }

        let capture = try await WorkspaceDirectoryScanner().snapshotCapture(root: root)
        XCTAssertEqual(
            Self.independentTokenRanges(in: body).count,
            Self.globalCapOccurrencesPerFile
        )

        return GlobalCapFixture(
            rootURL: root,
            capture: capture,
            orderedRelativePaths: orderedRelativePaths,
            totalByteCount: totalByteCount
        )
    }

    func makeAdmittedFileFixture() async throws -> SingleFileFixture {
        let root = try makeTemporaryDirectory(prefix: "WS4BAdmittedFile")
        let body = Self.makeExactlyAdmittedBody()
        try Data(body.utf8).write(to: root.appendingPathComponent("admitted.md"), options: .atomic)

        let capture = try await WorkspaceDirectoryScanner().snapshotCapture(root: root)
        let ranges = Self.independentTokenRanges(in: body)
        XCTAssertEqual(ranges.count, 1)
        let range = try XCTUnwrap(ranges.first)
        XCTAssertGreaterThan(range.location, Self.admittedFileByteCount - 512)

        return SingleFileFixture(
            rootURL: root,
            capture: capture,
            relativePath: "admitted.md",
            byteCount: body.utf8.count,
            expectedMatchRange: range,
            expectedLine: Self.lineNumber(ofUTF16Location: range.location, in: body)
        )
    }

    func makeAdmissionBoundaryFixture() async throws -> SingleFileFixture {
        let root = try makeTemporaryDirectory(prefix: "WS4BAdmissionBoundary")
        let admitted = Self.makeExactlyAdmittedBody()
        try Data(admitted.utf8).write(to: root.appendingPathComponent("admitted.md"), options: .atomic)

        // Deliberately far past the cap, not `cap + 1`. With a `cap + 1` sibling, a reader that
        // wrongly slurped the whole file would report exactly the same byte count as one that
        // stopped at the inclusive limit, so the probe could not tell them apart. At 8x the cap
        // the two are unmistakable: a bounded read contributes 524,289 bytes, an unbounded one
        // contributes 4,194,304.
        var oversized = Data()
        oversized.reserveCapacity(Self.oversizedFileByteCount)
        let chunk = Data(admitted.utf8)
        while oversized.count < Self.oversizedFileByteCount {
            oversized.append(chunk.prefix(Self.oversizedFileByteCount - oversized.count))
        }
        XCTAssertEqual(oversized.count, Self.oversizedFileByteCount)
        try oversized.write(to: root.appendingPathComponent("oversized.md"), options: .atomic)

        let capture = try await WorkspaceDirectoryScanner().snapshotCapture(root: root)
        let range = try XCTUnwrap(Self.independentTokenRanges(in: admitted).first)

        return SingleFileFixture(
            rootURL: root,
            capture: capture,
            relativePath: "admitted.md",
            byteCount: admitted.utf8.count,
            expectedMatchRange: range,
            expectedLine: Self.lineNumber(ofUTF16Location: range.location, in: admitted)
        )
    }

    func makeDenseWholeWordFixture(
        shape: DenseWholeWordShape
    ) async throws -> DenseWholeWordFixture {
        let root = try makeTemporaryDirectory(prefix: "WS4BDenseWholeWord")
        let unit: String
        let pattern: String
        switch shape {
        case .suffixRejected:
            // Every literal hit is immediately rejected because a word character follows it.
            unit = "\(Self.token)s "
            pattern = Self.token
        case .composedPeriodic:
            // Overlapping candidates in composed non-ASCII text: only the last position could
            // match, and every earlier one must be examined and rejected.
            unit = "e\u{0301}."
            pattern = String(repeating: unit, count: 64)
        }

        // Reserve at least one trailing word character so even the final candidate is rejected
        // by the closing boundary; every literal hit in the file must be examined and refused.
        let repetitions = (Self.admittedFileByteCount - 1) / unit.utf8.count
        let remainder = Self.admittedFileByteCount - repetitions * unit.utf8.count
        let body = String(repeating: unit, count: repetitions) + String(repeating: "z", count: remainder)
        XCTAssertEqual(body.utf8.count, Self.admittedFileByteCount, shape.rawValue)
        XCTAssertLessThanOrEqual(pattern.utf16.count, TextSearchEngine.maximumPatternUTF16Length)
        try Data(body.utf8).write(to: root.appendingPathComponent("dense.md"), options: .atomic)

        let capture = try await WorkspaceDirectoryScanner().snapshotCapture(root: root)
        return DenseWholeWordFixture(
            rootURL: root,
            capture: capture,
            relativePath: "dense.md",
            byteCount: body.utf8.count,
            pattern: pattern
        )
    }

    static func makeBody(index: Int, includesToken: Bool) -> String {
        let filler = "This deterministic paragraph gives workspace search ordinary prose to scan."
        var lines: [String] = []
        lines.append(String(format: "# Post %04d", index))
        lines.append("")
        lines.append(includesToken ? "Intro mentions \(token) once." : "Intro mentions nothing here.")
        lines.append("")
        for _ in 0 ..< 18 {
            lines.append(filler)
        }
        lines.append("")
        lines.append(includesToken ? "Outro mentions \(token) again." : "Outro mentions nothing again.")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// A CJK body of exactly the admission cap, with the CJK token at the end of file. CJK has no
    /// cased characters, so a `.smart` query over this text always resolves to the insensitive
    /// backend — the path the UI default actually takes for CJK input.
    static func makeExactlyAdmittedCJKBody() -> String {
        // The occurrence carries an upper-case Latin suffix while the query pattern carries a
        // lower-case one, so a `.sensitive` run over this file finds nothing and the `.smart`
        // run's single match is proof that the insensitive backend was selected.
        let tail = "\n最後一行提到\(cjkCasedOccurrence)。\n"
        let header = "# 中文全文搜尋容量上限\n\n"
        let unit = "這是一段用來測試工作區搜尋效能的中文內容，並不包含搜尋標記。\n"
        let unitByteCount = unit.utf8.count
        let available = admittedFileByteCount - header.utf8.count - tail.utf8.count
        precondition(available > 0)
        let wholeUnits = available / unitByteCount
        // CJK units rarely divide the cap exactly; pad the remainder with single-byte ASCII so
        // the file lands on the cap to the byte.
        let padding = available - wholeUnits * unitByteCount
        return header
            + String(repeating: unit, count: wholeUnits)
            + String(repeating: "a", count: padding)
            + tail
    }

    /// Mixed-case and CJK occurrences used to prove which matching backend `.smart` resolved to.
    static func makeSmartCaseBody() -> String {
        """
        # Smart case

        Lowercase occurrence: \(token).
        Title-case occurrence: \(titleCaseToken).
        Upper-case occurrence: \(upperCaseToken).

        中文出現一次：\(cjkToken)。
        中文再出現一次：\(cjkToken)。
        中文加上大寫拉丁字母：\(cjkCasedOccurrence)。
        """
    }

    static func makeExactlyAdmittedBody() -> String {
        let tail = "\nfinal line mentions \(token) at end of file.\n"
        let header = "# Admitted at exactly the workspace-search admission cap\n\n"
        let padding = admittedFileByteCount - header.utf8.count - tail.utf8.count
        precondition(padding > 0)
        return header + String(repeating: "a", count: padding) + tail
    }

    /// Locates the token with Foundation rather than `TextSearchEngine`, so the expected
    /// ranges are not produced by the code under measurement.
    static func independentTokenRanges(in text: String) -> [NSRange] {
        independentRanges(of: token, in: text)
    }

    static func independentRanges(of needle: String, in text: String) -> [NSRange] {
        let source = text as NSString
        var ranges: [NSRange] = []
        var searchStart = 0
        while searchStart < source.length {
            let searchRange = NSRange(location: searchStart, length: source.length - searchStart)
            let found = source.range(of: needle, options: [.literal], range: searchRange)
            guard found.location != NSNotFound else { break }
            ranges.append(found)
            searchStart = found.location + max(1, found.length)
        }
        return ranges
    }

    static func lineNumber(ofUTF16Location location: Int, in text: String) -> Int {
        let source = text as NSString
        var line = 1
        var index = 0
        while index < location, index < source.length {
            let character = source.character(at: index)
            if character == 0x0D {
                line += 1
                if index + 1 < source.length, source.character(at: index + 1) == 0x0A {
                    index += 1
                }
            } else if character == 0x0A {
                line += 1
            }
            index += 1
        }
        return line
    }

    func makeTemporaryDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(prefix)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return try WorkspaceFileSystemRootAuthority(rootURL: url).canonicalRootURL
    }

    func removeDirectory(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
