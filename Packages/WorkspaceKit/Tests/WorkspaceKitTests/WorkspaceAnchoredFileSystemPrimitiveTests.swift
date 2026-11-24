import Darwin
import Foundation
@testable import WorkspaceKit
import XCTest

final class WorkspaceAnchoredFileSystemPrimitiveTests: XCTestCase {
    func testDescriptorDigestMatchesDataDigestAcrossChunkBoundaries() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceAnchoredFileSystemPrimitiveTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        for byteCount in [0, 1, 64 * 1024, 64 * 1024 + 1, 3 * 64 * 1024 + 777] {
            let data = Data((0 ..< byteCount).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
            let fileURL = directory.appendingPathComponent("digest-\(byteCount).bin")
            try data.write(to: fileURL)
            let descriptor = Darwin.open(fileURL.path, O_RDONLY | O_CLOEXEC)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            defer { Darwin.close(descriptor) }

            XCTAssertEqual(
                try WorkspaceAnchoredFileSystem.sha256Digest(descriptor: descriptor),
                WorkspaceAnchoredFileSystem.sha256Digest(data),
                "byteCount \(byteCount)"
            )
        }
    }

    func testWithCStringPreservingErrnoReportsTheBodyErrno() {
        // Non-ASCII and long, so `withCString` cannot use an inline small-string buffer.
        let name = String(repeating: "檔案-é-", count: 64)
        errno = 0

        let result = name.withCStringPreservingErrno { pointer -> Int32 in
            XCTAssertEqual(String(cString: pointer), name)
            errno = EXDEV
            return -1
        }

        XCTAssertEqual(errno, EXDEV)
        XCTAssertEqual(result, -1)
    }
}
