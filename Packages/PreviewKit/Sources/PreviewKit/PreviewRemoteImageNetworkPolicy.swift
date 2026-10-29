import CryptoKit
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
    /// WebKit rejects `|` in a url-filter ("Disjunctions are not supported yet"), so ws(s)
    /// is a second trigger rather than one alternation. The image exception still ignores
    /// only https images; it does not unblock ws(s).
    static let blockSource = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},"#
        + #"{"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}}]"#
    static let imagesSource = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},"#
        + #"{"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}},"#
        + #"{"trigger":{"url-filter":"^https://","resource-type":["image"]},"#
        + #""action":{"type":"ignore-previous-rules"}}]"#
    static var blockIdentifier: String {
        identifier(prefix: "plainsong-preview-block", source: blockSource)
    }

    static var imagesIdentifier: String {
        identifier(prefix: "plainsong-preview-https-images", source: imagesSource)
    }

    /// A changed rule source gets a new store key, so a stale compiled list cannot be reused.
    static func identifier(prefix: String, source: String) -> String {
        let digest = SHA256.hash(data: Data(source.utf8))
        let hex = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        return "\(prefix)-\(hex)"
    }

    private static var cached: PreviewRemoteImageRules?
    private static var started = false
    private static var retiredRemoved = false
    private static var protectedIdentifiers: Set<String> = []
    private static var waiters: [(PreviewRemoteImageRules) -> Void] = []

    static func cachedRules() -> PreviewRemoteImageRules? {
        cached
    }

    /// Calls `completion` on the main thread. A cached result is delivered immediately.
    /// Compilation stays off the typing path: the first request starts it, and later
    /// requests reuse that result. A missing block list is not cached, so the next
    /// controller tries again.
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
    /// fails closed without replacing the process-wide rules. The caller removes
    /// `identifiers` from the store when the lists are no longer needed.
    static func makeRules(
        blockSource: String,
        imagesSource: String
    ) async -> (rules: PreviewRemoteImageRules, identifiers: [String]) {
        let token = UUID().uuidString
        let blockIdentifier = "plainsong-preview-test-block-\(token)"
        let imagesIdentifier = "plainsong-preview-test-images-\(token)"
        // Register before compile so a prefix sweep cannot delete an in-flight test list.
        protectStoredRules([blockIdentifier, imagesIdentifier])
        return await withCheckedContinuation { continuation in
            load(identifier: blockIdentifier, source: blockSource) { block in
                load(identifier: imagesIdentifier, source: imagesSource) { images in
                    continuation.resume(returning: (
                        combined(block: block, images: images),
                        [blockIdentifier, imagesIdentifier]
                    ))
                }
            }
        }
    }

    /// Keeps a preview identifier out of the prefix sweep. Tests call this before compile.
    static func protectStoredRules(_ identifiers: [String]) {
        protectedIdentifiers.formUnion(identifiers)
    }

    static func unprotectStoredRules(_ identifiers: [String]) {
        protectedIdentifiers.subtract(identifiers)
    }

    static func removeStoredRules(identifiers: [String], force: Bool = false) {
        for identifier in identifiers where force || !protectedIdentifiers.contains(identifier) {
            WKContentRuleListStore.default().removeContentRuleList(forIdentifier: identifier) { _ in }
        }
    }

    /// Compiles one list under `identifier` without protecting it. The stale-identifier test
    /// uses this so the prefix sweep has something it is allowed to delete.
    static func storeRuleForTesting(identifier: String, source: String) async -> WKContentRuleList? {
        await withCheckedContinuation { continuation in
            load(identifier: identifier, source: source) { rule in
                continuation.resume(returning: rule)
            }
        }
    }

    static func lookupStoredRule(identifier: String) async -> WKContentRuleList? {
        await withCheckedContinuation { continuation in
            WKContentRuleListStore.default().lookUpContentRuleList(forIdentifier: identifier) { rule, _ in
                if Thread.isMainThread {
                    continuation.resume(returning: rule)
                } else {
                    DispatchQueue.main.async { continuation.resume(returning: rule) }
                }
            }
        }
    }

    private static func startIfNeeded() {
        guard !started else { return }
        started = true
        if !retiredRemoved {
            retiredRemoved = true
            Task { await removeUnprotectedStaleRules() }
        }
        load(identifier: blockIdentifier, source: blockSource) { block in
            load(identifier: imagesIdentifier, source: imagesSource) { images in
                publish(combined(block: block, images: images))
            }
        }
    }

    /// Drops stale preview lists and the retired export list, preserving other features'
    /// namespaces. Current hashes and identifiers registered with `protectStoredRules`
    /// stay available, including lists a parallel test is still using.
    static func removeUnprotectedStaleRules() async {
        let identifiers = await WKContentRuleListStore.default().availableIdentifiers()
        let keep: Set = [blockIdentifier, imagesIdentifier]
        let legacy: Set = ["plainsong-export-no-http-v1"]
        let stale = (identifiers ?? []).filter { identifier in
            (identifier.hasPrefix("plainsong-preview-") || legacy.contains(identifier))
                && !keep.contains(identifier)
                && !protectedIdentifiers.contains(identifier)
        }
        // Each removal awaits WebKit, so protection may change before the next iteration.
        for identifier in stale where !protectedIdentifiers.contains(identifier) {
            try? await WKContentRuleListStore.default().removeContentRuleList(forIdentifier: identifier)
        }
    }

    private static func combined(block: WKContentRuleList?, images: WKContentRuleList?) -> PreviewRemoteImageRules {
        PreviewRemoteImageRules(blockAll: block, httpsImages: block == nil ? nil : images)
    }

    private static func publish(_ rules: PreviewRemoteImageRules) {
        let pending = waiters
        waiters.removeAll()
        if rules.blockAll == nil {
            // A transient store failure must not blank every later preview until relaunch.
            cached = nil
            started = false
        } else if cached == nil {
            cached = rules
        }
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
        guard !locksRemoteImagesOff else { return false }
        guard let liveRemoteImageRules else { return requested }
        let allowed = requested && liveRemoteImageRules.httpsImages != nil
        swapRemoteImageRule(liveRemoteImageRules.rule(allowingHTTPSImages: allowed))
        return allowed
    }

    /// Adds the next list before removing the previous one. The two lists overlap for one
    /// IPC, and both together still block, so that gap fails closed instead of falling
    /// open to the static `img-src https:` policy.
    func swapRemoteImageRule(_ next: WKContentRuleList?) {
        let controller = webView.configuration.userContentController
        guard activeContentRuleList !== next else { return }
        let previous = activeContentRuleList
        if let next {
            controller.add(next)
        }
        if let previous {
            controller.remove(previous)
        }
        activeContentRuleList = next
    }

    func loadRemoteImageRules(_ completion: @escaping (PreviewRemoteImageRules) -> Void) {
        if let remoteImageRulesLoader {
            remoteImageRulesLoader(completion)
        } else {
            PreviewRemoteImageRuleStore.whenReady(completion)
        }
    }

    /// One retry after a failed block-list compile, then one more per document. Neither
    /// path runs from every keystroke: the first is a single deferred attempt, and later
    /// attempts require the presented document to change.
    func scheduleInitialRemoteImageRecoveryIfNeeded() {
        guard awaitsRemoteImageRules, liveRemoteImageRules == nil, !didScheduleInitialRemoteImageRecovery else {
            return
        }
        didScheduleInitialRemoteImageRecovery = true
        DispatchQueue.main.async { [weak self] in
            self?.beginRemoteImageRecovery(consumeDocumentAttempt: false)
        }
    }

    func recoverRemoteImageNetworkPolicyIfNeeded() {
        beginRemoteImageRecovery(consumeDocumentAttempt: true)
    }

    private func beginRemoteImageRecovery(consumeDocumentAttempt: Bool) {
        guard awaitsRemoteImageRules, remoteImageNetworkUnavailable, liveRemoteImageRules == nil else { return }
        guard !remoteImageRecoveryInFlight else { return }
        if consumeDocumentAttempt {
            let documentID = presentedDocumentIdentifier ?? ""
            guard documentID != remoteImageRecoveryDocumentID else { return }
            remoteImageRecoveryDocumentID = documentID
        }
        remoteImageRecoveryInFlight = true
        loadRemoteImageRules { [weak self] rules in
            guard let self else { return }
            remoteImageRecoveryInFlight = false
            guard !isInvalidated, liveRemoteImageRules == nil, remoteImageNetworkUnavailable else {
                return
            }
            guard rules.blockAll != nil else { return }
            applyCompiledRemoteImageRules(rules)
        }
    }
}
