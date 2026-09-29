import AppKit
@testable import EditorKit
import MarkdownCore
import XCTest

@MainActor
enum EditorReplaceSingleSupport {
    struct Ready {
        let fixture: EditorReplaceBatchSpikeSupport.Fixture
        let controller: EditorFindController
        let session: EditorFindSession
    }

    static func makeReady(
        source: String,
        pattern: String,
        selection: NSRange? = nil,
        enableWYSIWYG: Bool = false
    ) async throws -> Ready {
        let fixture = try EditorReplaceBatchSpikeSupport.makeFixture(
            source: source,
            selection: NSRange(location: 0, length: 0),
            enableWYSIWYG: enableWYSIWYG
        )
        let controller = try await installController(
            on: fixture,
            source: source,
            pattern: pattern,
            selection: selection
        )
        return try Ready(
            fixture: fixture,
            controller: controller,
            session: XCTUnwrap(controller.session)
        )
    }

    static func installController(
        on fixture: EditorReplaceBatchSpikeSupport.Fixture,
        source: String,
        pattern: String,
        selection: NSRange? = nil
    ) async throws -> EditorFindController {
        let query = TextSearchQuery(pattern: pattern, caseSensitivity: .sensitive)
        let found = EditorFindSession.search(in: source, query: query)
        let match = try XCTUnwrap(found.currentMatch)
        fixture.textView.textSelection = selection ?? match.range
        let identity = try XCTUnwrap(fixture.coordinator.currentDocumentIdentity)
        let revision = try XCTUnwrap(
            fixture.coordinator.currentInstalledSourceSnapshot
        ).revision
        let controller = EditorFindController(
            documentBinding: EditorFindDocumentBinding(
                identity: identity,
                text: source,
                revision: UInt64(revision)
            )
        )
        controller.debounceNanoseconds = 0
        controller.setQuery(query)
        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) {
            controller.session?.currentMatch?.range == match.range
        }
        return controller
    }

    /// Routes every accepted publication to Find inside the native write, the way
    /// App's `notifyEditorFindDocumentDidChange` does.
    static func routePublicationsToFind(_ ready: Ready) {
        let controller = ready.controller
        ready.fixture.model.onAcceptedPublication = { snapshot in
            controller.documentTextDidChange(
                text: snapshot.source,
                revision: UInt64(snapshot.revision)
            )
        }
    }

    static func request(
        controller: EditorFindController,
        session: EditorFindSession,
        replacement: String
    ) -> EditorReplaceRequest {
        EditorReplaceRequest(
            documentIdentity: controller.documentBinding.identity,
            sourceRevision: controller.documentBinding.revision,
            queryGeneration: controller.queryGeneration,
            session: session,
            replacement: replacement
        )
    }

    static func perform(
        _ ready: Ready,
        replacement: String,
        authorization: EditorReplaceAuthorization = .allowed()
    ) -> EditorReplaceOutcome {
        ready.fixture.coordinator.performSingleReplace(
            request(
                controller: ready.controller,
                session: ready.session,
                replacement: replacement
            ),
            authorization: authorization,
            controller: ready.controller,
            in: ready.fixture.textView
        )
    }
}
