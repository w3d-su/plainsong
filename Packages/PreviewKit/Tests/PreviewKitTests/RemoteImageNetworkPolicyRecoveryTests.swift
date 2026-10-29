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

        func testStalePlainsongRuleIdentifiersAreRemovedUnlessProtected() async {
            let protected = await PreviewRemoteImageRuleStore.makeRules(
                blockSource: PreviewRemoteImageRuleStore.blockSource,
                imagesSource: PreviewRemoteImageRuleStore.imagesSource
            )
            let protectedIDs = protected.identifiers
            addTeardownBlock {
                PreviewRemoteImageRuleStore.unprotectStoredRules(protectedIDs)
                PreviewRemoteImageRuleStore.removeStoredRules(identifiers: protectedIDs, force: true)
            }
            let staleID = "plainsong-preview-block-stale"
            let stale = await PreviewRemoteImageRuleStore.storeRuleForTesting(
                identifier: staleID,
                source: PreviewRemoteImageRuleStore.blockSource
            )
            XCTAssertNotNil(stale)
            addTeardownBlock {
                PreviewRemoteImageRuleStore.removeStoredRules(identifiers: [staleID], force: true)
            }
            await PreviewRemoteImageRuleStore.removeUnprotectedStaleRules()
            let staleAfter = await PreviewRemoteImageRuleStore.lookupStoredRule(identifier: staleID)
            XCTAssertNil(staleAfter)
            for identifier in protectedIDs {
                let kept = await PreviewRemoteImageRuleStore.lookupStoredRule(identifier: identifier)
                XCTAssertNotNil(kept, "protected \(identifier) was removed")
            }
        }
    }
#endif
