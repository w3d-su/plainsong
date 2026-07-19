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

    func testImageInsertionHoldsExactWriterLeaseAcrossAwait() async throws {
        let scenario = try makeScenario(firstWriterIsPending: false)
        defer {
            dismantle(scenario.first)
            dismantle(scenario.second)
        }
        let gate = ImageInsertionGate()
        let firstURL = URL(fileURLWithPath: "/tmp/first.png")
        scenario.first.coordinator.updateImageAssetInserter { assets in
            await gate.insert(assets)
        }
        scenario.first.coordinator.attachPasteAndDragHandlers(to: scenario.first.textView)
        scenario.first.textView.textSelection = NSRange(location: 12, length: 0)

        XCTAssertEqual(scenario.first.textView.imageFileDropHandler?(
            scenario.first.textView,
            [firstURL]
        ), true)
        try await waitForImageInsertionInvocation(gate)
        XCTAssertEqual(gate.assets, [.file(firstURL)])
        XCTAssertEqual(scenario.model.pendingWriterInstallations, [scenario.firstInstallation])

        requestRejectedImageInsertion(in: scenario)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(scenario.model.imageInserterInvocationCount, 0)
        XCTAssertEqual(scenario.model.activeWriterInstallation, scenario.firstInstallation)

        gate.resume(relativePaths: ["assets/first.png"])
        try await waitForSource(in: scenario.model, toEqual: "Stale source![](assets/first.png)")
        XCTAssertTrue(scenario.model.pendingWriterInstallations.isEmpty)
        XCTAssertEqual(scenario.model.publications.count, 1)
        XCTAssertEqual(gate.commitCount, 1)
        XCTAssertEqual(gate.discardCount, 0)
    }

    func testImageInsertionSignalsCommitAfterPlacementValidationAndMarkdownPublication() async throws {
        let scenario = try makeScenario(firstWriterIsPending: false)
        defer {
            dismantle(scenario.first)
            dismantle(scenario.second)
        }
        let gate = ImagePlacementValidationGate()
        scenario.first.coordinator.updateImageAssetInserter { _ in
            EditorImageAssetInsertion(
                relativePaths: ["assets/first.png"],
                validateBeforeCommit: {
                    await gate.validate()
                },
                commit: {
                    gate.commitCount += 1
                },
                discard: {
                    gate.discardCount += 1
                }
            )
        }
        scenario.first.coordinator.attachPasteAndDragHandlers(to: scenario.first.textView)
        scenario.first.textView.textSelection = NSRange(location: 12, length: 0)

        XCTAssertEqual(scenario.first.textView.imageFileDropHandler?(
            scenario.first.textView,
            [URL(fileURLWithPath: "/tmp/first.png")]
        ), true)
        try await waitForPlacementValidationInvocation(gate)
        XCTAssertEqual(gate.commitCount, 0)

        gate.resume(isValid: true)
        try await waitForSource(in: scenario.model, toEqual: "Stale source![](assets/first.png)")

        XCTAssertEqual(gate.commitCount, 1)
        XCTAssertEqual(gate.discardCount, 0)
        XCTAssertEqual(scenario.model.publications.count, 1)
    }

    func testImageInsertionHoldsWriterLeaseThroughPlacementCommitValidation() async throws {
        let scenario = try makeScenario(firstWriterIsPending: false)
        defer {
            dismantle(scenario.first)
            dismantle(scenario.second)
        }
        let gate = ImagePlacementValidationGate()
        scenario.first.coordinator.updateImageAssetInserter { _ in
            EditorImageAssetInsertion(
                relativePaths: ["assets/first.png"],
                validateBeforeCommit: {
                    await gate.validate()
                },
                discard: {
                    gate.discardCount += 1
                }
            )
        }
        scenario.first.coordinator.attachPasteAndDragHandlers(to: scenario.first.textView)

        XCTAssertEqual(scenario.first.textView.imageFileDropHandler?(
            scenario.first.textView,
            [URL(fileURLWithPath: "/tmp/first.png")]
        ), true)
        try await waitForPlacementValidationInvocation(gate)
        XCTAssertEqual(scenario.model.pendingWriterInstallations, [scenario.firstInstallation])

        requestRejectedImageInsertion(in: scenario)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(scenario.model.imageInserterInvocationCount, 0)
        XCTAssertEqual(scenario.model.activeWriterInstallation, scenario.firstInstallation)

        gate.resume(isValid: false)
        try await waitForPlacementValidationDiscard(gate)

        XCTAssertEqual(scenario.model.source, "Stale source")
        XCTAssertEqual(Self.text(in: scenario.first.textView), "Stale source")
        XCTAssertTrue(scenario.model.publications.isEmpty)
        XCTAssertTrue(scenario.model.pendingWriterInstallations.isEmpty)
        XCTAssertEqual(scenario.model.activeWriterInstallation, scenario.firstInstallation)
    }

    func testImageInsertionRechecksContextAfterPlacementCommitValidation() async throws {
        let scenario = try makeScenario(firstWriterIsPending: false)
        defer {
            dismantle(scenario.first)
            dismantle(scenario.second)
        }
        let gate = ImagePlacementValidationGate()
        scenario.first.coordinator.updateImageAssetContextID("file-a")
        scenario.first.coordinator.updateImageAssetInserter { _ in
            EditorImageAssetInsertion(
                relativePaths: ["assets/first.png"],
                validateBeforeCommit: {
                    await gate.validate()
                },
                discard: {
                    gate.discardCount += 1
                }
            )
        }
        scenario.first.coordinator.attachPasteAndDragHandlers(to: scenario.first.textView)

        XCTAssertEqual(scenario.first.textView.imageFileDropHandler?(
            scenario.first.textView,
            [URL(fileURLWithPath: "/tmp/first.png")]
        ), true)
        try await waitForPlacementValidationInvocation(gate)
        scenario.first.coordinator.updateImageAssetContextID("file-b")

        gate.resume(isValid: true)
        try await waitForPlacementValidationDiscard(gate)

        XCTAssertEqual(scenario.model.source, "Stale source")
        XCTAssertEqual(Self.text(in: scenario.first.textView), "Stale source")
        XCTAssertTrue(scenario.model.publications.isEmpty)
        XCTAssertTrue(scenario.model.pendingWriterInstallations.isEmpty)
    }

    func testDismantledImageInsertionDiscardsPlacedAsset() async throws {
        let scenario = try makeScenario(firstWriterIsPending: false)
        var didDismantleFirst = false
        defer {
            if !didDismantleFirst {
                dismantle(scenario.first)
            }
            dismantle(scenario.second)
        }
        let gate = ImageInsertionGate()
        scenario.first.coordinator.updateImageAssetInserter { assets in
            await gate.insert(assets)
        }
        scenario.first.coordinator.attachPasteAndDragHandlers(to: scenario.first.textView)

        XCTAssertEqual(scenario.first.textView.imageFileDropHandler?(
            scenario.first.textView,
            [URL(fileURLWithPath: "/tmp/dismantled.png")]
        ), true)
        try await waitForImageInsertionInvocation(gate)

        dismantle(scenario.first)
        didDismantleFirst = true
        gate.resume(relativePaths: ["assets/dismantled.png"])
        try await waitForDiscardCount(1, in: gate)

        XCTAssertEqual(scenario.model.source, "Stale source")
        XCTAssertTrue(scenario.model.publications.isEmpty)
        XCTAssertTrue(scenario.model.pendingWriterInstallations.isEmpty)
    }

    func testDelayedImageInsertionRejectsCanonicalEquivalentContextChange() async throws {
        let scenario = try makeScenario(firstWriterIsPending: false)
        defer {
            dismantle(scenario.first)
            dismantle(scenario.second)
        }
        let gate = ImageInsertionGate()
        let nfcContext = "/tmp/caf\u{00E9}.md"
        let nfdContext = "/tmp/cafe\u{0301}.md"
        XCTAssertEqual(nfcContext, nfdContext)
        XCTAssertFalse(ExactSourceText.matches(nfcContext, nfdContext))
        scenario.first.coordinator.updateImageAssetContextID(nfcContext)
        scenario.first.coordinator.updateImageAssetInserter { assets in
            await gate.insert(assets)
        }
        scenario.first.coordinator.attachPasteAndDragHandlers(to: scenario.first.textView)

        XCTAssertEqual(scenario.first.textView.imageFileDropHandler?(
            scenario.first.textView,
            [URL(fileURLWithPath: "/tmp/canonical-context.png")]
        ), true)
        try await waitForImageInsertionInvocation(gate)
        let capturedGeneration = scenario.first.coordinator.imageAssetInsertionGeneration

        scenario.first.coordinator.updateImageAssetContextID(nfdContext)

        XCTAssertEqual(
            scenario.first.coordinator.imageAssetInsertionGeneration,
            capturedGeneration + 1,
            "raw-different context must supersede the delayed insertion"
        )
        // Exercise the independent commit-time context fence even if generation equality
        // were accidentally restored by a future lifecycle change.
        scenario.first.coordinator.imageAssetInsertionGeneration = capturedGeneration
        gate.resume(relativePaths: ["assets/canonical-context.png"])
        try await waitForDiscardCount(1, in: gate)

        XCTAssertEqual(scenario.model.source, "Stale source")
        XCTAssertEqual(Self.text(in: scenario.first.textView), "Stale source")
        XCTAssertTrue(scenario.model.publications.isEmpty)
        XCTAssertTrue(scenario.model.pendingWriterInstallations.isEmpty)
    }

    func testRejectedImagePublicationDiscardsPlacedAsset() async throws {
        let scenario = try makeScenario(firstWriterIsPending: false)
        defer {
            dismantle(scenario.first)
            dismantle(scenario.second)
        }
        scenario.model.rejectNextPublication = true
        scenario.first.coordinator.updateImageAssetInserter { _ in
            EditorImageAssetInsertion(
                relativePaths: ["assets/rejected.png"],
                discard: {
                    scenario.model.imageDiscardCount += 1
                }
            )
        }
        scenario.first.coordinator.attachPasteAndDragHandlers(to: scenario.first.textView)

        XCTAssertEqual(scenario.first.textView.imageFileDropHandler?(
            scenario.first.textView,
            [URL(fileURLWithPath: "/tmp/rejected.png")]
        ), true)
        try await waitForImageDiscardCount(1, in: scenario.model)

        XCTAssertEqual(scenario.model.source, "Stale source")
        XCTAssertEqual(Self.text(in: scenario.first.textView), "Stale source")
        XCTAssertEqual(scenario.model.publications.count, 1)
        XCTAssertTrue(scenario.model.pendingWriterInstallations.isEmpty)
        XCTAssertNil(scenario.model.activeWriterInstallation)
    }
}

@MainActor
private extension EditorProgrammaticWriterActivationTests {
    final class Model {
        var source = "Stale source"
        var revision = 0
        var activeWriterInstallation: EditorDocumentBindingInstallation?
        var pendingWriterInstallations: Set<EditorDocumentBindingInstallation> = []
        var lifecycleEvents: [EditorDocumentBindingLifecycleEvent] = []
        var writerEvents: [EditorDocumentWriterEvent] = []
        var pendingSourceEvents: [EditorDocumentPendingSourceEvent] = []
        var publications: [EditorDocumentSourcePublication] = []
        var imageInserterInvocationCount = 0
        var imageDiscardCount = 0
        var rejectNextPublication = false
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
                pendingSource: { self.handlePendingSourceEvent($0) },
                publish: { self.handlePublication($0) }
            )
        }

        private func handleWriterEvent(
            _ event: EditorDocumentWriterEvent
        ) -> EditorDocumentWriterEventResult {
            writerEvents.append(event)
            switch event {
            case let .activate(installation, base):
                if base.revision != revision {
                    if activeWriterInstallation == installation,
                       !pendingWriterInstallations.contains(installation)
                    {
                        activeWriterInstallation = nil
                    }
                    return .synchronize(snapshot)
                }
                if let activeWriterInstallation,
                   activeWriterInstallation != installation,
                   pendingWriterInstallations.contains(activeWriterInstallation)
                {
                    return .rejected(snapshot)
                }
                activeWriterInstallation = installation
                return .activated(snapshot)
            case let .release(installation):
                guard activeWriterInstallation == installation,
                      !pendingWriterInstallations.contains(installation)
                else {
                    return .releaseRejected
                }
                activeWriterInstallation = nil
                return .released
            }
        }

        private func handlePendingSourceEvent(_ event: EditorDocumentPendingSourceEvent) {
            pendingSourceEvents.append(event)
            switch event {
            case let .began(installation):
                if activeWriterInstallation == installation {
                    pendingWriterInstallations.insert(installation)
                }
            case let .synchronized(installation), let .abandoned(installation):
                pendingWriterInstallations.remove(installation)
            }
        }

        private func handlePublication(
            _ publication: EditorDocumentSourcePublication
        ) -> EditorDocumentSourcePublicationResult {
            publications.append(publication)
            if rejectNextPublication {
                rejectNextPublication = false
                return .rejected(snapshot)
            }
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
        let firstInstallation: EditorDocumentBindingInstallation
        let blockedInstallation: EditorDocumentBindingInstallation
    }

    func makeScenario(firstWriterIsPending: Bool = true) throws -> Scenario {
        let model = Model()
        let contract = model.makeContract()
        let source = Binding(get: { model.source }, set: { model.source = $0 })
        let first = try makeFixture(source: source, bindingID: model.bindingID, contract: contract)
        let second = try makeFixture(source: source, bindingID: model.bindingID, contract: contract)
        let installations = model.lifecycleEvents.compactMap(\.installedInstallation)
        XCTAssertEqual(installations.count, 2)
        let firstInstallation = try XCTUnwrap(installations.first)
        model.activeWriterInstallation = firstInstallation
        if firstWriterIsPending {
            model.pendingWriterInstallations.insert(firstInstallation)
        }
        return try Scenario(
            model: model,
            first: first,
            second: second,
            firstInstallation: firstInstallation,
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
        scenario.second.coordinator.updateImageAssetInserter { _ in
            scenario.model.imageInserterInvocationCount += 1
            return EditorImageAssetInsertion(relativePaths: ["assets/blocked.png"])
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
        XCTAssertEqual(scenario.model.imageInserterInvocationCount, 0)
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

    func waitForImageInsertionInvocation(_ gate: ImageInsertionGate) async throws {
        for _ in 0 ..< 20 {
            if gate.invocationCount == 1 { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(gate.invocationCount, 1)
    }

    func waitForSource(in model: Model, toEqual expected: String) async throws {
        for _ in 0 ..< 20 {
            if model.source == expected { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(model.source, expected)
    }

    func waitForDiscardCount(_ expected: Int, in gate: ImageInsertionGate) async throws {
        for _ in 0 ..< 20 {
            if gate.discardCount == expected { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(gate.discardCount, expected)
    }

    func waitForImageDiscardCount(_ expected: Int, in model: Model) async throws {
        for _ in 0 ..< 20 {
            if model.imageDiscardCount == expected { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(model.imageDiscardCount, expected)
    }

    func waitForPlacementValidationInvocation(
        _ gate: ImagePlacementValidationGate
    ) async throws {
        for _ in 0 ..< 20 {
            if gate.invocationCount == 1 { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(gate.invocationCount, 1)
    }

    func waitForPlacementValidationDiscard(
        _ gate: ImagePlacementValidationGate
    ) async throws {
        for _ in 0 ..< 20 {
            if gate.discardCount == 1 { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(gate.discardCount, 1)
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

@MainActor
private final class ImageInsertionGate {
    private var continuation: CheckedContinuation<EditorImageAssetInsertion, Never>?
    private(set) var assets: [EditorImageAsset] = []
    private(set) var invocationCount = 0
    private(set) var commitCount = 0
    private(set) var discardCount = 0

    func insert(_ assets: [EditorImageAsset]) async -> EditorImageAssetInsertion {
        self.assets = assets
        invocationCount += 1
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume(relativePaths: [String]) {
        continuation?.resume(returning: EditorImageAssetInsertion(
            relativePaths: relativePaths,
            commit: { [weak self] in
                self?.commitCount += 1
            },
            discard: { [weak self] in
                self?.discardCount += 1
            }
        ))
        continuation = nil
    }
}

@MainActor
private final class ImagePlacementValidationGate {
    private var continuation: CheckedContinuation<Bool, Never>?
    private(set) var invocationCount = 0
    var commitCount = 0
    var discardCount = 0

    func validate() async -> Bool {
        invocationCount += 1
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume(isValid: Bool) {
        continuation?.resume(returning: isValid)
        continuation = nil
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
