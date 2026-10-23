import Foundation
import MarkdownCore
@testable import PreviewKit
import WebKit

/// Suppress all real page loads and deliver even cancelled deadlines manually.
@MainActor
final class InitialReadinessTestClock {
    @MainActor
    final class Deadline {
        let delay: UInt64
        let action: @MainActor () -> Void
        var isCancelled = false

        init(delay: UInt64, action: @escaping @MainActor () -> Void) {
            self.delay = delay
            self.action = action
        }
    }

    var deadlines: [Deadline] = []

    func schedule(after delay: UInt64, fire: @escaping @MainActor () -> Void) -> PreviewInitialReadiness.Cancellation {
        let deadline = Deadline(delay: delay, action: fire)
        deadlines.append(deadline)
        return { deadline.isCancelled = true }
    }

    func fire(_ index: Int = 0) {
        deadlines[index].action()
    }
}

@MainActor
final class InitialReadinessTestPage {
    var loads: [URL?] = []
    var messages: [BridgeMessage] = []

    func load(_: WKWebView, index: URL?) -> WKNavigation? {
        loads.append(index)
        return nil
    }

    func send(_ message: BridgeMessage, completion: (@MainActor (Bool) -> Void)?) {
        messages.append(message)
        completion?(true)
    }

    var renderedPayloads: [RenderPayload] {
        messages.compactMap {
            if case let .render(payload) = $0 {
                return payload
            }
            return nil
        }
    }
}

@MainActor
struct InitialReadinessTestFixture {
    let clock: InitialReadinessTestClock
    let page: InitialReadinessTestPage
    let controller: PreviewController

    init(index: URL? = nil, recoversFromTermination: Bool = false) {
        let clock = InitialReadinessTestClock()
        let page = InitialReadinessTestPage()
        self.clock = clock
        self.page = page
        controller = PreviewController(
            previewIndexURL: index,
            recoversFromWebContentTermination: recoversFromTermination,
            initialReadinessScheduler: clock.schedule,
            pageLoadOverrideForTesting: page.load
        )
        controller.bridgeTransportOverrideForTesting = page.send
    }

    static func change(_ text: String, version: Int = 1, file: URL? = nil) -> DocumentTextChange {
        DocumentTextChange(text: text, version: version, fileKind: .markdown, fileURL: file)
    }

    static var ready: BridgeMessage {
        .ready(ReadyPayload(protocolVersion: PreviewBridge.protocolVersion))
    }
}
