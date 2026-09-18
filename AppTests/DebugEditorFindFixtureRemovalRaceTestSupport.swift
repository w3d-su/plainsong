#if DEBUG
    import Foundation
    @testable import Plainsong

    enum EditorFindRemovalRaceTestError: Error {
        case afterMarkerReplacement
        case afterKnownChildRemoval
        case afterLeaseQuarantine
        case afterOwnershipMarkerUnlink
        case afterExactWorkspaceRemoval
    }

    func makeRemovalRaceLocations(
        prefix: String
    ) throws -> (container: URL, root: URL) {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "EditorFind\(prefix)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: container,
            withIntermediateDirectories: false
        )
        return (
            container,
            container.appendingPathComponent(
                "PlainsongEditorFindUITests",
                isDirectory: true
            )
        )
    }

    func makeRemovalRaceEntryExpired(
        _ url: URL,
        relativeTo now: Date
    ) throws {
        try FileManager.default.setAttributes(
            [
                .modificationDate:
                    now.addingTimeInterval(
                        -DebugEditorFindFixture.staleFixtureAge - 1
                    ),
            ],
            ofItemAtPath: url.path
        )
    }
#endif
