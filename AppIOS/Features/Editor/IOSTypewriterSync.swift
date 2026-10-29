import Foundation

/// Keeps the editor and preview on the same source line.
///
/// The side that moved last owns sync for a short decay, so a programmatic
/// scroll does not bounce back and forth. Navigation and editing stay on the
/// editor; this type only forwards line numbers.
@MainActor
final class IOSTypewriterSync {
    /// Matches the macOS scroll-owner decay.
    static let ownerDecayNanoseconds: UInt64 = 100_000_000

    private(set) var isEnabled = false
    var scrollPreview: ((Int) -> Void)?
    var scrollEditor: ((Int) -> Void)?

    private var claimed: Owner = .none
    private var deadline: UInt64 = 0
    private var now: @MainActor () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }

    func setEnabled(_ enabled: Bool, editorLine: Int?) {
        let becameEnabled = enabled && !isEnabled
        isEnabled = enabled
        guard becameEnabled, let editorLine, editorLine > 0 else { return }
        claim(.editor)
        scrollPreview?(editorLine)
    }

    func editorViewportChanged(to line: Int) {
        guard isEnabled, line > 0, !isOwned(by: .preview) else { return }
        claim(.editor)
        scrollPreview?(line)
    }

    func previewScrolled(to line: Int) {
        guard isEnabled, line > 0, !isOwned(by: .editor) else { return }
        claim(.preview)
        scrollEditor?(line)
    }

    func installClockForTesting(_ clock: @escaping @MainActor () -> UInt64) {
        now = clock
    }

    private func isOwned(by owner: Owner) -> Bool {
        claimed == owner && now() < deadline
    }

    private func claim(_ owner: Owner) {
        claimed = owner
        deadline = now() &+ Self.ownerDecayNanoseconds
    }

    private enum Owner {
        case editor
        case preview
        case none
    }
}
