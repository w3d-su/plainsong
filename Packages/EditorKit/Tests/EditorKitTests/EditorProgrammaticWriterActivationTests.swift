import AppKit
@testable import EditorKit
import MarkdownCore
import STTextView
import SwiftUI
import XCTest

@MainActor
final class EditorProgrammaticWriterActivationTests: XCTestCase {
    func testStaleSecondCoordinatorPreflightsEveryProgrammaticTextMutation() async throws {
        let scenario = try makeScenario()
        defer {
            dismantle(scenario.first)
            dismantle(scenario.second)
        }

        // The second native buffer is now stale while another installation owns the
        // App writer. Its first command may synchronize to the current source, but the
        // command itself must never touch either stale or current native text.
        scenario.model.replaceSourceWithCurrentVersion()
        assertCommandIsRejected(in: scenario)
        assertCompletionIsRejected(in: scenario)
        assertSmartPasteIsRejected(in: scenario)
        requestRejectedImageInsertion(in: scenario)

        try await waitForActivationCount(4) { scenario.model.writerEvents }
        assertOnlyPreflightSynchronizationOccurred(in: scenario)
    }
}

@MainActor
private extension EditorProgrammaticWriterActivationTests {
    final class Model {
        var source = "Stale source"
        var revision = 0
        var activeWriterInstallation: EditorDocumentBindingInstallation?
        var lifecycleEvents: [EditorDocumentBindingLifecycleEvent] = []
        var writerEvents: [EditorDocumentWriterEvent] = []
        var publications: [EditorDocumentSourcePublication] = []
        let bindingID = EditorDocumentBindingID()

        var snapshot: EditorDocumentSourceSnapshot {
            EditorDocumentSourceSnapshot(source: source, revision: revision)
        }

        func replaceSourceWithCurrentVersion() {
            source = "Current source"
            revision += 1
        }

        func makeContract() -> EditorDocumentSourceContract {
            EditorDocumentSourceContract(
                bindingID: bindingID,
                snapshot: { self.snapshot },
                lifecycle: { self.lifecycleEvents.append($0) },
                writer: { self.handleWriterEvent($0) },
                pendingSource: { _ in },
                publish: { self.handlePublication($0) }
            )
        }

        private func handleWriterEvent(
            _ event: EditorDocumentWriterEvent
        ) -> EditorDocumentWriterEventResult {
            writerEvents.append(event)
            switch event {
            case let .activate(installation, _):
                if let activeWriterInstallation,
                   activeWriterInstallation != installation
                {
                    return .rejected(snapshot)
                }
                activeWriterInstallation = installation
                return .activated(snapshot)
            case let .release(installation):
                if activeWriterInstallation == installation {
                    activeWriterInstallation = nil
                }
                return .released
            }
        }

        private func handlePublication(
            _ publication: EditorDocumentSourcePublication
        ) -> EditorDocumentSourcePublicationResult {
            publications.append(publication)
            source = publication.source
            revision += 1
            return .accepted(snapshot, sourceWasReconciled: false)
        }
    }

    struct Fixture {
        let window: NSWindow
        let scrollView: NSScrollView
        let textView: MarkdownSTTextView
        let coordinator: MarkdownTextViewCoordinator
    }

    struct Scenario {
        let model: Model
        let first: Fixture
        let second: Fixture
        let blockedInstallation: EditorDocumentBindingInstallation
    }

    func makeScenario() throws -> Scenario {
        let model = Model()
        let contract = model.makeContract()
        let source = Binding(get: { model.source }, set: { model.source = $0 })
        let first = try makeFixture(source: source, bindingID: model.bindingID, contract: contract)
        let second = try makeFixture(source: source, bindingID: model.bindingID, contract: contract)
        let installations = model.lifecycleEvents.compactMap(\.installedInstallation)
        XCTAssertEqual(installations.count, 2)
        model.activeWriterInstallation = try XCTUnwrap(installations.first)
        return try Scenario(
            model: model,
            first: first,
            second: second,
            blockedInstallation: XCTUnwrap(installations.last)
        )
    }

    func assertCommandIsRejected(in scenario: Scenario) {
        scenario.second.textView.textSelection = NSRange(location: 0, length: 5)
        scenario.second.coordinator.performCommand(
            .format(.bold),
            in: scenario.second.textView
        )
        XCTAssertEqual(Self.text(in: scenario.second.textView), "Current source")
        XCTAssertEqual(scenario.model.source, "Current source")
        XCTAssertTrue(scenario.model.publications.isEmpty)
    }

    func assertCompletionIsRejected(in scenario: Scenario) {
        let completion = MarkdownCompletionItem(completion: Completion(
            label: "Fresh",
            insertText: "Fresh",
            kind: .snippet,
            replacementRange: NSRange(location: 0, length: 7)
        ))
        scenario.second.textView.textSelection = NSRange(location: 7, length: 0)
        scenario.second.coordinator.textView(
            scenario.second.textView,
            insertCompletionItem: completion
        )
        XCTAssertEqual(Self.text(in: scenario.second.textView), "Current source")
        XCTAssertTrue(scenario.second.coordinator.recentCompletionIDs.isEmpty)
    }

    func assertSmartPasteIsRejected(in scenario: Scenario) {
        scenario.second.coordinator.attachPasteAndDragHandlers(to: scenario.second.textView)
        let pasteboard = Self.uniquePasteboard()
        pasteboard.setString("https://example.com", forType: .string)
        scenario.second.textView.textSelection = NSRange(location: 0, length: 7)
        XCTAssertEqual(
            scenario.second.textView.pasteHandler?(scenario.second.textView, pasteboard),
            true
        )
        XCTAssertEqual(Self.text(in: scenario.second.textView), "Current source")
    }

    func requestRejectedImageInsertion(in scenario: Scenario) {
        let blockedURL = URL(fileURLWithPath: "/tmp/blocked.png")
        scenario.second.coordinator.updateImageAssetInserter { assets in
            XCTAssertEqual(assets, [.file(blockedURL)])
            return ["assets/blocked.png"]
        }
        scenario.second.coordinator.attachPasteAndDragHandlers(to: scenario.second.textView)
        scenario.second.textView.textSelection = NSRange(location: 14, length: 0)
        XCTAssertEqual(scenario.second.textView.imageFileDropHandler?(
            scenario.second.textView,
            [blockedURL]
        ), true)
    }

    func assertOnlyPreflightSynchronizationOccurred(in scenario: Scenario) {
        XCTAssertEqual(Self.text(in: scenario.second.textView), "Current source")
        XCTAssertEqual(scenario.model.source, "Current source")
        XCTAssertTrue(scenario.model.publications.isEmpty)
        XCTAssertEqual(
            scenario.model.writerEvents.compactMap(\.activatedInstallation),
            Array(repeating: scenario.blockedInstallation, count: 4)
        )
    }

    func makeFixture(
        source: Binding<String>,
        bindingID: EditorDocumentBindingID,
        contract: EditorDocumentSourceContract
    ) throws -> Fixture {
        let frame = NSRect(x: 0, y: 0, width: 560, height: 100)
        let scrollView = MarkdownSTTextView.scrollableTextView(frame: frame)
        let textView = try XCTUnwrap(scrollView.documentView as? MarkdownSTTextView)
        textView.text = source.wrappedValue
        let representable = MarkdownTextView(
            text: source,
            styledText: nil,
            selection: .constant(nil),
            showsLineNumbers: false,
            documentIdentity: EditorDocumentIdentity(rawValue: "shared-document"),
            documentBindingID: bindingID,
            onDocumentBindingLifecycle: { _ in },
            documentSourceContract: contract
        )
        let coordinator = representable.makeCoordinator()
        textView.textDelegate = coordinator
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        window.makeKeyAndOrderFront(nil)
        representable.updateRepresentedTextView(scrollView, coordinator: coordinator)
        return Fixture(
            window: window,
            scrollView: scrollView,
            textView: textView,
            coordinator: coordinator
        )
    }

    func dismantle(_ fixture: Fixture) {
        fixture.coordinator.detachPasteAndDragHandlers(from: fixture.textView)
        MarkdownTextView.dismantleNSView(
            fixture.scrollView,
            coordinator: fixture.coordinator
        )
        fixture.window.orderOut(nil)
    }

    func waitForActivationCount(
        _ expectedCount: Int,
        writerEvents: @escaping @MainActor () -> [EditorDocumentWriterEvent]
    ) async throws {
        for _ in 0 ..< 20 {
            if writerEvents().compactMap(\.activatedInstallation).count == expectedCount {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(writerEvents().compactMap(\.activatedInstallation).count, expectedCount)
    }

    static func text(in textView: STTextView) -> String {
        MarkdownTextView.textStorage(of: textView)?.string ?? textView.text ?? ""
    }

    static func uniquePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PlainsongTests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }
}

private extension EditorDocumentBindingLifecycleEvent {
    var installedInstallation: EditorDocumentBindingInstallation? {
        guard case let .installed(installation) = self else { return nil }
        return installation
    }
}

private extension EditorDocumentWriterEvent {
    var activatedInstallation: EditorDocumentBindingInstallation? {
        guard case let .activate(installation, _) = self else { return nil }
        return installation
    }
}
