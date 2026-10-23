import EditorKitIOS
import Foundation
import MarkdownCore
import WorkspaceCore
import WorkspaceKitIOS

/// Only opaque admission is process-wide for this single-window product. It
/// owns no document, source or grant. A retained discarded scene cannot permit
/// a recreated runtime to race its still-live UIDocument writer.
@MainActor
final class IOSSceneWriterAdmission {
    static let process = IOSSceneWriterAdmission()
    private var value = IOSOpenDocumentAdmission()
    var active: IOSOpenDocumentAdmission.Ticket? {
        value.active
    }

    func begin(documentID: IOSDocumentIdentity)
        -> Result<IOSOpenDocumentAdmission.Ticket, IOSOpenDocumentAdmission.Refusal>
    {
        value.begin(documentID: documentID)
    }

    func end(_ ticket: IOSOpenDocumentAdmission.Ticket) {
        value.end(ticket)
    }
}

extension IOSDocumentSceneController {
    /// True scene disconnection, never a transient sheet disappearance. Keep a
    /// retained writer and its admission if recovery/close cannot safely finish.
    func shutdown() async -> Bool {
        if isDisposed {
            return true
        }
        isShuttingDown = true
        updateEditorAccess()
        while transitioning {
            do { try await Task.sleep(nanoseconds: 10_000_000) }
            catch { isShuttingDown = false; return false }
        }
        _ = await documents.flushForBackground()
        do { try await closeCurrent() }
        catch {
            isShuttingDown = false
            updateEditorAccess()
            return false
        }
        let grant = currentGrant
        currentGrant = nil
        grantIsCurrent = false
        workspaceSnapshot = nil
        if let grant {
            _ = workspace.invalidate(grant.workspaceID)
        }
        renderTask?.cancel()
        reloadRelay.detach()
        documentObservation?.cancel()
        workspaceObservation?.cancel()
        editorObservation?.cancel()
        previewObservation?.cancel()
        preview.invalidate()
        isDisposed = true
        return true
    }

    func newDocumentLocation(in parent: IOSFileLocation) throws -> IOSFileLocation {
        guard grantIsCurrent, let grant = currentGrant, grant.scope == .directory,
              parent.workspaceID == grant.workspaceID, parent.accessGeneration == grant.accessGeneration
        else {
            throw IOSDocumentFailure.access(.outsideGrant)
        }
        let rootParent = parent.relativePath.isEmpty &&
            parent.fileURL.path(percentEncoded: false).utf8
            .elementsEqual(grant.rootURL.path(percentEncoded: false).utf8)
        let knownDirectory = Self.flatten(workspaceSnapshot?.entries ?? []).contains {
            guard case .directory = $0.kind, case .available(canWrite: true) = $0.availability else { return false }
            return Self.sameLocation($0.location, parent) &&
                $0.location.fileURL.path(percentEncoded: false).utf8
                .elementsEqual(parent.fileURL.path(percentEncoded: false).utf8)
        }
        guard rootParent || knownDirectory else { throw IOSDocumentFailure.access(.outsideGrant) }
        let occupied = Set(Self.flatten(workspaceSnapshot?.entries ?? []).map { Data($0.location.relativePath.utf8) })
        for index in 1 ... 1000 {
            let name = index == 1 ? "Untitled.md" : "Untitled \(index).md"
            let relative = parent.relativePath.isEmpty ? name : parent.relativePath + "/" + name
            guard WorkspaceRelativePath(spelling: relative) != nil else { throw IOSWorkspaceFailure.invalidPath }
            if occupied.contains(Data(relative.utf8)) {
                continue
            }
            var path = grant.rootURL.path(percentEncoded: false)
            if !path.hasSuffix("/") {
                path.append("/")
            }
            path.append(relative)
            var components = URLComponents()
            components.scheme = "file"
            components.path = path
            guard let url = components.url else { throw IOSWorkspaceFailure.invalidPath }
            return IOSFileLocation(
                workspaceID: grant.workspaceID, accessGeneration: grant.accessGeneration,
                relativePath: relative, fileURL: url, resourceID: nil
            )
        }
        throw IOSWorkspaceFailure.alreadyExists
    }

    func applyPreviewCheckbox(revision: IOSDocumentRevision, line: Int, checked: Bool) {
        guard !transitioning, grantIsCurrent, !isShuttingDown,
              let capture = editor.captureSnapshot(), capture.revision == revision,
              capture.bindingID == bindingID, capture.canWrite, !capture.hasMarkedText,
              line > 0 else { return }
        let source = capture.document.text as NSString
        var offset = 0
        for _ in 1 ..< line {
            guard offset < source.length else { return }
            offset = NSMaxRange(source.lineRange(for: NSRange(location: offset, length: 0)))
        }
        guard offset < source.length else { return }
        let range = source.lineRange(for: NSRange(location: offset, length: 0))
        let text = source.substring(with: range) as NSString
        guard let expression = try? NSRegularExpression(pattern: #"^\s*(?:[-+*]|\d+[.)])\s+\[([ xX])\]"#),
              let match = expression.firstMatch(in: text as String, range: NSRange(location: 0, length: text.length)),
              match.numberOfRanges == 2 else { return }
        let marker = match.range(at: 1)
        let current = text.substring(with: marker) != " "
        guard current != checked else { return }
        let edit = IOSAuthorizedEdit(
            bindingID: capture.bindingID, baseRevision: capture.revision,
            selectionGeneration: capture.selectionGeneration, accessGeneration: capture.accessGeneration,
            result: MarkdownEditResult(
                replacementRange: NSRange(location: range.location + marker.location, length: 1),
                replacementString: checked ? "x" : " ", newSelection: capture.selection
            ), undoActionName: "Toggle Checkbox"
        )
        _ = editor.apply(edit)
    }
}
