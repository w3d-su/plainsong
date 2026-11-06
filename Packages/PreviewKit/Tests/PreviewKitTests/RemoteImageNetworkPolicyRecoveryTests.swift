#if os(macOS)
    import Foundation
    import MarkdownCore
    @testable import PreviewKit
    import XCTest

    /// Recovery and store cleanup are separate from the proxy waves so the wave class stays
    /// inside the lint type-body limit.
    @MainActor
    final class RemoteImageNetworkPolicyRecoveryTests: XCTestCase {
        func testFailedBlockListRetriesOncePerDocumentAndNotOnEveryRender() async {
            let good = await PreviewRemoteImageRuleStore.rules()
            let failed = PreviewRemoteImageRules(blockAll: nil, httpsImages: nil)
            var scripted = [failed, failed, failed, good]
            var calls = 0
            let controller = PreviewController(
                previewIndexURL: nil,
                pageLoadOverrideForTesting: { _, _ in nil },
                remoteImageRulesLoader: { completion in
                    calls += 1
                    completion(scripted.isEmpty ? failed : scripted.removeFirst())
                }
            )
            defer { controller.invalidate() }
            XCTAssertEqual(calls, 1)
            XCTAssertTrue(controller.remoteImageNetworkUnavailable)
            XCTAssertNil(controller.activeContentRuleList)

            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
            XCTAssertEqual(calls, 2)
            XCTAssertTrue(controller.remoteImageNetworkUnavailable)

            let change = DocumentTextChange(text: "hello", version: 1, fileKind: .markdown, fileURL: nil)
            controller.renderForTesting(change)
            controller.renderForTesting(change)
            controller.renderForTesting(change)
            XCTAssertEqual(calls, 3, "Same-document renders must not compile on every keystroke")
            XCTAssertTrue(controller.remoteImageNetworkUnavailable)

            controller.setPresentedDocumentIdentifier("doc-b")
            controller.renderForTesting(change)
            XCTAssertEqual(calls, 4)
            XCTAssertFalse(controller.remoteImageNetworkUnavailable)
            XCTAssertTrue(controller.activeContentRuleList === good.blockAll)
        }

        func testStalePreviewRulesAreRemovedWithoutDeletingOtherFeatures() async {
            let current = await PreviewRemoteImageRuleStore.rules()
            XCTAssertNotNil(current.blockAll)
            XCTAssertNotNil(current.httpsImages)
            let protected = await PreviewRemoteImageRuleStore.makeRules(
                blockSource: PreviewRemoteImageRuleStore.blockSource,
                imagesSource: PreviewRemoteImageRuleStore.imagesSource
            )
            let protectedIDs = protected.identifiers
            addTeardownBlock {
                PreviewRemoteImageRuleStore.unprotectStoredRules(protectedIDs)
                PreviewRemoteImageRuleStore.removeStoredRules(identifiers: protectedIDs, force: true)
            }
            let token = UUID().uuidString
            let staleIDs = [
                "plainsong-preview-block-stale-\(token)",
                "plainsong-preview-https-images-stale-\(token)",
                "plainsong-export-no-http-v1",
            ]
            let unrelatedID = "plainsong-other-feature-\(token)"
            let storedIDs = staleIDs + [unrelatedID]
            addTeardownBlock {
                PreviewRemoteImageRuleStore.removeStoredRules(identifiers: storedIDs, force: true)
            }
            for identifier in storedIDs {
                let stored = await PreviewRemoteImageRuleStore.storeRuleForTesting(
                    identifier: identifier,
                    source: PreviewRemoteImageRuleStore.blockSource
                )
                XCTAssertNotNil(stored)
            }
            await PreviewRemoteImageRuleStore.removeUnprotectedStaleRules()
            for identifier in staleIDs {
                let stale = await PreviewRemoteImageRuleStore.lookupStoredRule(identifier: identifier)
                XCTAssertNil(stale, "stale \(identifier) was kept")
            }
            let keptIDs = protectedIDs + [
                unrelatedID,
                PreviewRemoteImageRuleStore.blockIdentifier,
                PreviewRemoteImageRuleStore.imagesIdentifier,
            ]
            for identifier in keptIDs {
                let kept = await PreviewRemoteImageRuleStore.lookupStoredRule(identifier: identifier)
                XCTAssertNotNil(kept, "retained \(identifier) was removed")
            }
        }
    }
#endif
