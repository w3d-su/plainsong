import EditorKitIOS
import Foundation
import MarkdownCore

extension IOSAuthoringController {
    func noteFrontmatterSource(using editor: any IOSSourceEditorControlling) {
        guard let snapshot = editor.captureSnapshot() else { return }
        projectFrontmatter(snapshot)
    }

    func startObservingFrontmatter(using editor: any IOSSourceEditorControlling) {
        stopObservingFrontmatter()
        noteFrontmatterSource(using: editor)
        guard let binding = editor as? any IOSSourceEditorBinding else { return }
        frontmatterObservation = binding.observe { [weak self] event in
            guard let self else { return }
            switch event {
            case let .snapshotChanged(snapshot):
                projectFrontmatter(snapshot)
            case let .detached(_, bindingID):
                guard frontmatter.projectedSnapshot?.bindingID == bindingID else { return }
                frontmatter.projectedSnapshot = nil
                frontmatter.acceptedText = ""
                frontmatter.acceptedParse = FrontmatterParseResult(block: nil)
                frontmatter.liveParse = frontmatter.acceptedParse
                if frontmatter.drafts.isEmpty {
                    frontmatter.capture = nil
                }
            }
        }
    }

    func stopObservingFrontmatter() {
        frontmatterObservation?.cancel()
        frontmatterObservation = nil
    }

    func beginFrontmatterDraft(using editor: any IOSSourceEditorControlling) {
        guard let snapshot = editor.captureSnapshot() else { return }
        projectFrontmatter(snapshot)
        if frontmatter.drafts.isEmpty {
            frontmatter.capture = snapshot
            frontmatter.needsRecapture = false
        }
    }

    func setFrontmatterDraft(key: String, value: FrontmatterValue, using editor: any IOSSourceEditorControlling) {
        if frontmatter.drafts.isEmpty {
            beginFrontmatterDraft(using: editor)
        }
        frontmatter.drafts[key] = value
    }

    func discardFrontmatterDrafts(using editor: any IOSSourceEditorControlling) {
        frontmatter.drafts.removeAll()
        frontmatter.capture = nil
        frontmatter.needsRecapture = false
        noteFrontmatterSource(using: editor)
        statusMessage = ""
    }

    func displayedFrontmatterValue(_ field: FrontmatterField) -> FrontmatterValue {
        guard let capture = frontmatter.capture, let projected = frontmatter.projectedSnapshot,
              capture.bindingID == projected.bindingID,
              capture.revision.documentID == projected.revision.documentID
        else { return field.value }
        return frontmatter.drafts[field.key] ?? field.value
    }

    private func projectFrontmatter(_ snapshot: IOSSourceEditorSnapshot) {
        let changed = frontmatter.projectedSnapshot?.bindingID != snapshot.bindingID ||
            frontmatter.projectedSnapshot?.revision != snapshot.revision ||
            !ExactSourceText.matches(frontmatter.acceptedText, snapshot.document.text)
        frontmatter.projectedSnapshot = snapshot
        if changed {
            frontmatter.acceptedText = snapshot.document.text
            frontmatter.acceptedParse = Frontmatter.parse(snapshot.document.text)
            frontmatter.liveParse = frontmatter.acceptedParse
        }
        if frontmatter.drafts.isEmpty {
            frontmatter.capture = snapshot
            frontmatter.needsRecapture = false
        }
    }

    func commitFrontmatter(
        key: String,
        value: FrontmatterValue,
        using editor: any IOSSourceEditorControlling
    ) {
        guard value.isEditable else {
            statusMessage = IOSAuthoringCatalog.frontmatterRefusal
            return
        }
        guard let snapshot = frontmatterCommitSnapshot(using: editor) else { return }
        if snapshot.hasMarkedText {
            statusMessage = IOSAuthoringCatalog.compositionRefusal
            frontmatter.drafts[key] = value
            frontmatter.needsRecapture = true
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
            frontmatter.drafts[key] = nil
            noteFrontmatterSource(using: editor)
            return
        }
        let outcome = submit(result, snapshot: snapshot, name: "Frontmatter", using: editor)
        switch outcome {
        case .applied:
            frontmatter.needsRecapture = false
            frontmatter.drafts[key] = nil
            frontmatter.capture = editor.captureSnapshot()
        case .refused:
            frontmatter.needsRecapture = true
            frontmatter.drafts[key] = value
        }
        noteFrontmatterSource(using: editor)
    }

    private func frontmatterCommitSnapshot(
        using editor: any IOSSourceEditorControlling
    ) -> IOSSourceEditorSnapshot? {
        guard let fresh = editor.captureSnapshot() else { return nil }
        if let capture = frontmatter.capture,
           capture.bindingID != fresh.bindingID || capture.revision.documentID != fresh.revision.documentID
        {
            statusMessage = "This draft belongs to another document. Discard it before editing this document."
            projectFrontmatter(fresh)
            return nil
        }
        if frontmatter.needsRecapture || frontmatter.capture == nil {
            frontmatter.capture = fresh
            return fresh
        }
        return frontmatter.capture
    }

    func toggleFrontmatterBool(key: String, using editor: any IOSSourceEditorControlling) {
        guard let snapshot = editor.captureSnapshot() else { return }
        if let capture = frontmatter.capture, !frontmatter.drafts.isEmpty,
           capture.bindingID != snapshot.bindingID || capture.revision.documentID != snapshot.revision.documentID
        {
            statusMessage = "This draft belongs to another document. Discard it before editing this document."
            projectFrontmatter(snapshot)
            return
        }
        frontmatter.capture = snapshot
        frontmatter.needsRecapture = false
        let parsed = Frontmatter.parse(snapshot.document.text)
        let current = frontmatter.drafts[key] ?? parsed.block?.fieldValues[key]
        let next: Bool = if case let .bool(value) = current {
            !value
        } else {
            true
        }
        commitFrontmatter(key: key, value: .bool(next), using: editor)
    }

    func insertDefaultFrontmatter(date: String, using editor: any IOSSourceEditorControlling) {
        guard let snapshot = editor.captureSnapshot() else { return }
        projectFrontmatter(snapshot)
        let parsed = Frontmatter.parse(snapshot.document.text)
        guard parsed.block == nil, parsed.error == nil else {
            statusMessage = "Frontmatter already exists in this document."
            return
        }
        if snapshot.hasMarkedText {
            statusMessage = IOSAuthoringCatalog.compositionRefusal
            return
        }
        let updated = Frontmatter.insertingDefaultBlock(into: snapshot.document.text, date: date)
        guard let result = IOSAuthoringSourceDiff.edit(
            from: snapshot.document.text,
            to: updated,
            selection: snapshot.selection
        ) else { return }
        let outcome = submit(result, snapshot: snapshot, name: "Frontmatter", using: editor)
        if case .applied = outcome {
            frontmatter.needsRecapture = false
            frontmatter.capture = editor.captureSnapshot()
        }
        noteFrontmatterSource(using: editor)
    }
}
