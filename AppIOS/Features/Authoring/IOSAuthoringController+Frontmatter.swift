import EditorKitIOS
import Foundation
import MarkdownCore

extension IOSAuthoringController {
    func noteFrontmatterSource(using editor: any IOSSourceEditorControlling) {
        guard let snapshot = editor.captureSnapshot() else { return }
        if frontmatter.capture == nil {
            frontmatter.capture = snapshot
            frontmatter.acceptedText = snapshot.document.text
            frontmatter.acceptedParse = Frontmatter.parse(snapshot.document.text)
        }
        frontmatter.liveParse = Frontmatter.parse(snapshot.document.text)
    }

    func beginFrontmatterDraft(using editor: any IOSSourceEditorControlling) {
        guard frontmatter.capture == nil || frontmatter.needsRecapture else { return }
        guard let snapshot = editor.captureSnapshot() else { return }
        frontmatter.capture = snapshot
        if frontmatter.acceptedText.isEmpty {
            frontmatter.acceptedText = snapshot.document.text
            frontmatter.acceptedParse = Frontmatter.parse(snapshot.document.text)
        }
    }

    func commitFrontmatter(
        key: String,
        value: FrontmatterValue,
        using editor: any IOSSourceEditorControlling
    ) {
        let snapshot: IOSSourceEditorSnapshot
        if frontmatter.needsRecapture || frontmatter.capture == nil {
            guard let fresh = editor.captureSnapshot() else { return }
            frontmatter.capture = fresh
            snapshot = fresh
        } else if let capture = frontmatter.capture {
            snapshot = capture
        } else {
            return
        }
        guard value.isEditable else {
            statusMessage = IOSAuthoringCatalog.frontmatterRefusal
            return
        }
        if snapshot.hasMarkedText {
            statusMessage = IOSAuthoringCatalog.compositionRefusal
            frontmatter.drafts[key] = value
            return
        }
        guard let updated = Frontmatter.updating(snapshot.document.text, key: key, value: value) else {
            statusMessage = IOSAuthoringCatalog.frontmatterRefusal
            frontmatter.drafts[key] = value
            return
        }
        guard let result = IOSAuthoringSourceDiff.edit(
            from: snapshot.document.text,
            to: updated,
            selection: snapshot.selection
        ) else {
            return
        }
        let outcome = submit(result, snapshot: snapshot, name: "Frontmatter", using: editor)
        switch outcome {
        case .applied:
            frontmatter.needsRecapture = false
            frontmatter.drafts[key] = nil
            if let latest = editor.captureSnapshot() {
                frontmatter.capture = latest
                frontmatter.acceptedText = latest.document.text
                frontmatter.acceptedParse = Frontmatter.parse(latest.document.text)
                frontmatter.liveParse = frontmatter.acceptedParse
            }
        case .refused:
            frontmatter.needsRecapture = true
            frontmatter.drafts[key] = value
        }
    }

    func toggleFrontmatterBool(key: String, using editor: any IOSSourceEditorControlling) {
        guard let snapshot = editor.captureSnapshot() else { return }
        frontmatter.capture = snapshot
        frontmatter.needsRecapture = false
        let parsed = Frontmatter.parse(snapshot.document.text)
        let current = frontmatter.drafts[key] ?? parsed.block?.fieldValues[key]
        let next: Bool = if case let .bool(value) = current { !value } else { true }
        commitFrontmatter(key: key, value: .bool(next), using: editor)
    }

    func insertDefaultFrontmatter(date: String, using editor: any IOSSourceEditorControlling) {
        guard let snapshot = editor.captureSnapshot() else { return }
        if snapshot.hasMarkedText {
            statusMessage = IOSAuthoringCatalog.compositionRefusal
            return
        }
        let updated = Frontmatter.insertingDefaultBlock(into: snapshot.document.text, date: date)
        guard let result = IOSAuthoringSourceDiff.edit(
            from: snapshot.document.text,
            to: updated,
            selection: snapshot.selection
        ) else {
            return
        }
        let outcome = submit(result, snapshot: snapshot, name: "Frontmatter", using: editor)
        if case .applied = outcome, let latest = editor.captureSnapshot() {
            frontmatter.capture = latest
            frontmatter.needsRecapture = false
            frontmatter.acceptedText = latest.document.text
            frontmatter.acceptedParse = Frontmatter.parse(latest.document.text)
            frontmatter.liveParse = frontmatter.acceptedParse
        }
    }
}
