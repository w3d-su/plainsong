import AppKit

/// The query field is registered at mount, and checked live only at command boundaries.
/// PR H can register its replacement field through the same seam without changing order.
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
