import Foundation
import MarkdownCore
@testable import WorkspaceKitIOS
import XCTest

final class IOSCloudVersionTests: XCTestCase {
    func testBothChoicesResolveOnlyAfterTheSelectedBytesAreOnDisk() throws {
        for keepCurrent in [true, false] {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            let review = try fixture.review()
            let selected = try XCTUnwrap(review.choices.first { $0.isCurrent == keepCurrent })
            try fixture.apply(selected.id, review: review)
            XCTAssertEqual(try Data(contentsOf: fixture.original), Data(selected.source.utf8))
            XCTAssertEqual(fixture.bytesWhenResolved, [Data(selected.source.utf8)])
            XCTAssertEqual(fixture.installs, keepCurrent ? 0 : 1)
        }
    }

    func testChangedBytesChangedSetAndRevocationKeepVersionsUnresolved() throws {
        for change in ["current source", "competing source", "version set", "revocation", "failed replacement"] {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            let review = try fixture.review()
            let selected = try XCTUnwrap(review.choices.last)
            let cancellation = Progress(totalUnitCount: 1)
            switch change {
            case "current source": try Data("é".utf8).write(to: fixture.original)
            case "competing source": try Data("new text".utf8).write(to: fixture.other)
            case "version set": fixture.conflictID = "new version"
            case "revocation": cancellation.cancel()
            default: fixture.failInstall = true
            }
            let before = try Data(contentsOf: fixture.original)
            XCTAssertThrowsError(try fixture.apply(selected.id, review: review, cancellation: cancellation))
            XCTAssertTrue(fixture.bytesWhenResolved.isEmpty)
            XCTAssertEqual(try Data(contentsOf: fixture.original), before)
        }
    }

    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var original: URL {
            root.appendingPathComponent("document.md")
        }

        var other: URL {
            root.appendingPathComponent("other")
        }

        var conflictID = "conflict"
        var installs = 0
        var failInstall = false
        var bytesWhenResolved: [Data] = []
        init() throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("e\u{301}".utf8).write(to: original)
            try Data("雲端草稿".utf8).write(to: other)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }

        func versions() -> [IOSCloudFileVersion] {
            [
                IOSCloudFileVersion(
                    key: IOSCloudVersionKey(identifier: "current", isCurrent: true), url: original,
                    device: nil, date: nil, install: { _ in XCTFail("Current bytes already exist") },
                    resolve: { XCTFail("Current version must never be marked resolved") }
                ),
                IOSCloudFileVersion(
                    key: IOSCloudVersionKey(identifier: conflictID, isCurrent: false), url: other,
                    device: "iPad", date: nil, install: { destination in
                        if self.failInstall { throw IOSDocumentFailure.saveFailed }
                        self.installs += 1
                        try Data(contentsOf: self.other).write(to: destination)
                    }, resolve: { self.bytesWhenResolved.append((try? Data(contentsOf: self.original)) ?? Data()) }
                ),
            ]
        }

        func review() throws -> IOSCloudVersionReview {
            try IOSCloudVersionReview(
                revision: IOSDocumentRevision(documentID: IOSDocumentIdentity(rawValue: UUID()), version: 1),
                choices: IOSCloudVersionIO.choices(from: versions(), limit: 1024)
            )
        }

        func apply(
            _ selected: UUID,
            review: IOSCloudVersionReview,
            cancellation: Progress = Progress(totalUnitCount: 1)
        ) throws {
            try IOSCloudVersionIO.apply(
                selected, review: review, at: original, versions: versions(), limit: 1024, cancellation: cancellation
            )
        }
    }
}
