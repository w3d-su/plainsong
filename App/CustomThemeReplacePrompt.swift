import AppKit

enum CustomThemeReplacePrompt {
    static func alert(identifier: String, name: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Replace theme \"\(name)\"?"
        alert.informativeText = """
        A theme with the id \"\(identifier)\" is already imported. Replacing it overwrites \
        Plainsong's copy. The file you selected is not changed.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        return alert
    }

    @MainActor
    static func confirm(identifier: String, name: String) -> Bool {
        alert(identifier: identifier, name: name).runModal() == .alertFirstButtonReturn
    }
}
