import Foundation
import WebKit

/// The two compiled content-rule lists for the live preview. `httpsImages` is nil when that
/// list failed to compile; the switch then stays off. `blockAll` nil means the preview
/// cannot be loaded, because there is no network block to fail closed to.
struct PreviewRemoteImageRules {
    let blockAll: WKContentRuleList?
    let httpsImages: WKContentRuleList?

    func rule(allowingHTTPSImages: Bool) -> WKContentRuleList? {
        if allowingHTTPSImages, blockAll != nil {
            return httpsImages
        }
        return blockAll
    }
}

/// Compiles the preview's content rules once per process and reuses the on-disk store.
/// `ignore-previous-rules` applies only inside one list, so the https-image exception has to
/// live in the same list as its block and that list is swapped in whole. Installing both
/// lists at once leaves the block in force.
@MainActor
enum PreviewRemoteImageRuleStore {
    static let blockIdentifier = "plainsong-preview-block-http-v1"
    static let imagesIdentifier = "plainsong-preview-https-images-v1"
    static let blockSource = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#
    static let imagesSource = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},"#
        + #"{"trigger":{"url-filter":"^https://","resource-type":["image"]},"#
        + #""action":{"type":"ignore-previous-rules"}}]"#

    private static var cached: PreviewRemoteImageRules?
    private static var started = false
    private static var waiters: [(PreviewRemoteImageRules) -> Void] = []

    static func cachedRules() -> PreviewRemoteImageRules? {
        cached
    }

    /// Calls `completion` on the main thread. A cached result is delivered immediately.
    /// Compilation stays off the typing path: the first request starts it, and later
    /// requests reuse that result.
    static func whenReady(_ completion: @escaping (PreviewRemoteImageRules) -> Void) {
        if let cached {
            completion(cached)
            return
        }
        waiters.append(completion)
        startIfNeeded()
    }

    static func rules() async -> PreviewRemoteImageRules {
        await withCheckedContinuation { continuation in
            whenReady { continuation.resume(returning: $0) }
        }
    }

    /// Compiles caller-supplied sources under fresh identifiers. Used to prove a bad list
    /// fails closed without replacing the process-wide rules.
    static func makeRules(blockSource: String, imagesSource: String) async -> PreviewRemoteImageRules {
        let token = UUID().uuidString
        return await withCheckedContinuation { continuation in
            load(identifier: "plainsong-preview-test-block-\(token)", source: blockSource) { block in
                load(identifier: "plainsong-preview-test-images-\(token)", source: imagesSource) { images in
                    continuation.resume(returning: combined(block: block, images: images))
                }
            }
        }
    }

    private static func startIfNeeded() {
        guard !started else { return }
        started = true
        load(identifier: blockIdentifier, source: blockSource) { block in
            load(identifier: imagesIdentifier, source: imagesSource) { images in
                publish(combined(block: block, images: images))
            }
        }
    }

    private static func combined(block: WKContentRuleList?, images: WKContentRuleList?) -> PreviewRemoteImageRules {
        PreviewRemoteImageRules(blockAll: block, httpsImages: block == nil ? nil : images)
    }

    private static func publish(_ rules: PreviewRemoteImageRules) {
        guard cached == nil else { return }
        cached = rules
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0(rules) }
    }

    private static func load(
        identifier: String,
        source: String,
        completion: @escaping (WKContentRuleList?) -> Void
    ) {
        let deliver: (WKContentRuleList?) -> Void = { rule in
            if Thread.isMainThread {
                completion(rule)
            } else {
                DispatchQueue.main.async { completion(rule) }
            }
        }
        WKContentRuleListStore.default().lookUpContentRuleList(forIdentifier: identifier) { existing, _ in
            if let existing {
                deliver(existing)
                return
            }
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: source
            ) { rule, _ in
                deliver(rule)
            }
        }
    }
}

extension PreviewController {
    /// The network layer is updated before JavaScript is told about the new flag, so an
    /// image whose `src` is restored cannot race ahead of the rule that should allow it.
    func enforcedRemoteImageAllowance(_ requested: Bool) -> Bool {
        guard let liveRemoteImageRules else { return requested }
        let allowed = requested && liveRemoteImageRules.httpsImages != nil
        swapRemoteImageRule(liveRemoteImageRules.rule(allowingHTTPSImages: allowed))
        return allowed
    }

    func swapRemoteImageRule(_ next: WKContentRuleList?) {
        let controller = webView.configuration.userContentController
        if let activeContentRuleList {
            if activeContentRuleList === next { return }
            controller.remove(activeContentRuleList)
            self.activeContentRuleList = nil
        }
        if let next {
            controller.add(next)
            activeContentRuleList = next
        }
    }
}
