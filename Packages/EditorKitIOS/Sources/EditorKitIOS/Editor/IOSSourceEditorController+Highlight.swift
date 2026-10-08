import MarkdownCore
import SyntaxKit
import UIKit

struct IOSHighlightContext: Sendable {
    let epoch: UInt64
    let request: SyntaxRequest
    let documentRawID: UUID
    let presentationGeneration: UInt64
    let themeID: String
}

extension IOSSourceEditorController {
    func scheduleHighlight() {
        guard isHostAlive, isContentVisible, installation != nil, syntaxTokenizer != nil else { return }
        guard textView.markedTextRange == nil else { return }
        scheduler.restart { [weak self] epoch in
            await self?.performHighlight(epoch: epoch)
        }
    }

    func raisePresentationFloor() {
        presentationGeneration &+= 1
        presentationFloor = presentationGeneration
        scheduler.invalidateInFlight()
    }

    private func performHighlight(epoch: UInt64) async {
        guard let tokenizer = syntaxTokenizer, let context = makeHighlightContext(epoch: epoch) else { return }
        let result: SyntaxResult
        do {
            result = try await tokenizer.tokens(for: context.request)
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        applyHighlight(result, context: context)
    }

    private func makeHighlightContext(epoch: UInt64) -> IOSHighlightContext? {
        guard isHostAlive, epoch == scheduler.epoch, let installation else { return nil }
        guard textView.markedTextRange == nil else { return nil }
        let source = plainText()
        let visible = IOSViewport.visibleUTF16Range(in: textView)
        guard IOSTextRanges.substring(source, range: visible) != nil || visible.length == 0 else { return nil }
        presentationGeneration &+= 1
        let generation = presentationGeneration
        guard generation >= presentationFloor else { return nil }
        let request = SyntaxRequest(
            requestID: UUID(),
            version: installation.session.version,
            source: source,
            fileKind: installation.session.fileKind,
            visibleRange: visible
        )
        return IOSHighlightContext(
            epoch: epoch,
            request: request,
            documentRawID: installation.identity.rawValue,
            presentationGeneration: generation,
            themeID: theme.identifier
        )
    }

    private func applyHighlight(_ result: SyntaxResult, context: IOSHighlightContext) {
        guard isHostAlive, context.epoch == scheduler.epoch else { return }
        guard context.presentationGeneration >= presentationFloor else { return }
        guard context.presentationGeneration == presentationGeneration else { return }
        guard context.themeID == theme.identifier else { return }
        guard let installation, installation.identity.rawValue == context.documentRawID else { return }
        guard installation.session.version == result.version else { return }
        guard result.requestID == context.request.requestID, result.version == context.request.version else { return }
        guard IOSViewport.visibleUTF16Range(in: textView) == context.request.visibleRange else { return }
        guard textView.markedTextRange == nil else { return }
        guard let expected = IOSTextRanges.substring(context.request.source, range: result.coveredRange) else {
            return
        }
        _ = IOSHighlightPresenter.apply(
            tokens: result.tokens,
            coveredRange: result.coveredRange,
            expectedFragment: expected,
            theme: theme,
            to: textView
        )
    }
}
