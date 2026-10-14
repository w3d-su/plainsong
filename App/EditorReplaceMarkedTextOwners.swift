import AppKit

/// The owned query and replacement fields register at mount and unregister at dismantle;
/// composition is read live only at command boundaries (Replace, Replace All's entry and
/// final recheck, and the bar's responder-chain Escape). The editor is the third owner and
/// is read through EditorKit instead (`docs/editor-replace-gates.md` §5.5).
@MainActor
final class EditorReplaceMarkedTextOwners {
    private struct Owner {
        weak var field: NSTextField?
    }

    private var owners: [ObjectIdentifier: Owner] = [:]
    var hasMarkedTextForTesting: (() -> Bool)?

    func register(_ field: NSTextField) {
        owners[ObjectIdentifier(field)] = Owner(field: field)
    }

    func unregister(_ field: NSTextField) {
        owners.removeValue(forKey: ObjectIdentifier(field))
    }

    func hasMarkedText(in window: ObjectIdentifier) -> Bool {
        if hasMarkedTextForTesting?() == true {
            return true
        }
        return owners.values.contains { owner in
            guard let field = owner.field, let fieldWindow = field.window,
                  ObjectIdentifier(fieldWindow) == window,
                  let editor = field.currentEditor() as? NSTextView
            else { return false }
            return editor.hasMarkedText()
        }
    }
}
