import UIKit

struct PresentationTicket: Sendable {
    let documentID: UUID
    let revision: Int
    let generation: UInt64
    let source: String
}

@MainActor
final class SourceEditor: NSObject, UITextViewDelegate {
    let textView = UITextView(usingTextLayoutManager: true)
    private(set) var documentID = UUID()
    private(set) var revision = 0
    private(set) var generation: UInt64 = 0
    var delayNanoseconds: UInt64 = 150_000_000
    var changed: (() -> Void)?
    var event: ((String) -> Void)?
    private var lastSource = ""

    override init() {
        super.init()
        textView.delegate = self
        textView.font = .monospacedSystemFont(ofSize: 17, weight: .regular)
        textView.autocorrectionType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.accessibilityIdentifier = "m0-source"
    }

    @discardableResult
    func attach(_ source: String, identity: UUID = UUID()) -> Bool {
        guard textView.markedTextRange == nil else { event?("attach-refused-marked"); return false }
        revision = identity == documentID ? revision + 1 : 0
        documentID = identity
        generation &+= 1
        textView.text = source
        lastSource = source
        textView.undoManager?.removeAllActions()
        schedulePresentation()
        event?("attach")
        return true
    }

    func textViewDidChange(_ textView: UITextView) {
        if !sameSource(lastSource, textView.text) {
            revision += 1
            lastSource = textView.text
        }
        event?("native-change")
        changed?()
        schedulePresentation()
    }

    func textViewDidChangeSelection(_: UITextView) {
        event?("native-selection")
        // Composition can end with a selection event rather than another edit.
        schedulePresentation()
    }

    func ticket() -> PresentationTicket {
        PresentationTicket(documentID: documentID, revision: revision,
                           generation: generation, source: textView.text)
    }

    func schedulePresentation() {
        generation &+= 1
        let captured = ticket()
        let delay = delayNanoseconds
        // Deliberately allow old work to return. Final checks must stand on their own.
        Task { [weak self] in
            let ranges = await Task.detached {
                try? await Task.sleep(nanoseconds: delay)
                let regex = try? NSRegularExpression(pattern: "(?m)^#+[^\\n]*")
                return regex?.matches(in: captured.source, range: NSRange(location: 0,
                                                                          length: captured.source.utf16.count))
                    .map(\.range) ?? []
            }.value
            self?.applyPresentation(captured, ranges: ranges)
        }
    }

    @discardableResult
    func applyPresentation(_ captured: PresentationTicket, ranges: [NSRange]) -> Bool {
        guard captured.documentID == documentID, captured.revision == revision,
              captured.generation == generation, sameSource(captured.source, textView.text)
        else {
            event?("presentation-refused-stale"); return false
        }
        guard textView.markedTextRange == nil else { event?("presentation-refused-marked"); return false }
        guard let layout = textView.textLayoutManager, let content = layout.textContentManager else {
            event?("presentation-refused-no-textkit2"); return false
        }
        let source = textView.text ?? ""
        let selection = textView.selectedRange
        let undo = textView.undoManager?.canUndo
        let redo = textView.undoManager?.canRedo
        layout.removeRenderingAttribute(.foregroundColor, for: content.documentRange)
        for range in ranges {
            guard range.location >= 0, range.length >= 0,
                  range.location <= source.utf16.count,
                  range.length <= source.utf16.count - range.location,
                  let start = content.location(content.documentRange.location, offsetBy: range.location),
                  let end = content.location(start, offsetBy: range.length),
                  let textRange = NSTextRange(location: start, end: end) else { continue }
            layout.setRenderingAttributes([.foregroundColor: UIColor.systemBlue], for: textRange)
        }
        textView.setNeedsDisplay()
        let intact = sameSource(source, textView.text) && selection == textView.selectedRange &&
            undo == textView.undoManager?.canUndo && redo == textView.undoManager?.canRedo
        event?(intact ? "presentation-applied" : "FAIL-presentation-mutated-native-state")
        return intact
    }

    func undo() {
        guard textView.markedTextRange == nil else { event?("undo-refused-marked"); return }
        textView.undoManager?.undo()
        event?("undo")
    }

    func redo() {
        guard textView.markedTextRange == nil else { event?("redo-refused-marked"); return }
        textView.undoManager?.redo()
        event?("redo")
    }
}
