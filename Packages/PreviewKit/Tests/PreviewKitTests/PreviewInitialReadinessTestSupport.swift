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

    var scheduler: PreviewInitialReadiness.Scheduler {
        { delay, fire in
            let deadline = Deadline(delay: delay) { fire() }
            self.deadlines.append(deadline)
            return { deadline.isCancelled = true }
        }
    }

    func fire(_ index: Int = 0) {
        deadlines[index].action()
    }
}

@MainActor
final class InitialReadinessTestPage {
    var loads: [URL?] = []
    var messages: [BridgeMessage] = []
    var readinessReplies: [@MainActor (Any?) -> Void] = []

    func probeReadiness(completion: @escaping @MainActor (Any?) -> Void) {
        readinessReplies.append(completion)
    }

    func load(_: WKWebView, index: URL?) -> WKNavigation? {
        loads.append(index)
        return nil
    }

    func installBridgeTransport(on controller: PreviewController) {
        controller.bridgeTransportOverrideForTesting = { message, completion in
            self.messages.append(message)
            completion?(true)
        }
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
            retriesSilentInitialLoad: true,
            initialReadinessScheduler: clock.scheduler,
            pageLoadOverrideForTesting: page.load
        )
        page.installBridgeTransport(on: controller)
        controller.readinessProbeOverrideForTesting = { reply in
            page.probeReadiness { reply($0) }
        }
    }

    static func change(_ text: String, version: Int = 1, file: URL? = nil) -> DocumentTextChange {
        DocumentTextChange(text: text, version: version, fileKind: .markdown, fileURL: file)
    }

    static var ready: BridgeMessage {
        .ready(ReadyPayload(protocolVersion: PreviewBridge.protocolVersion))
    }
}
