import AppKit

extension MarkdownTextView {
    /// Applies find-match decoration when the request, or the document it belongs to, changed (F8).
    ///
    /// A `nil` request must still reach `apply` when something is currently decorated — that is
    /// how closing the find bar clears its highlight. Bookkeeping therefore may only be
    /// forgotten on a real document identity change, never on an ordinary update.
    func applyFindMatchHighlightIfNeeded(
        _ coordinator: Coordinator,
        to textView: MarkdownSTTextView
    ) {
        let documentChanged = coordinator.appliedFindMatchHighlightDocumentIdentity != documentIdentity
        guard let textStorage = Self.textStorage(of: textView) else { return }
        coordinator.trackFindHighlightEdits(in: textStorage)

        let visibleRange = coordinator.lastVisibleTextRange
        // Decoration is materialised for a padded viewport window. Refreshing on every scroll
        // tick would re-decorate constantly; refresh only once the viewport leaves that window.
        let viewportLeftMaterialisedWindow: Bool = if findMatchHighlight == nil {
            false
        } else if let visibleRange, let applied = coordinator.appliedFindMatchHighlightMaterialisation {
            !EditorFindMatchHighlight.range(applied, contains: visibleRange)
        } else {
            coordinator.appliedFindMatchHighlightMaterialisation == nil
        }

        guard documentChanged
            || coordinator.appliedFindMatchHighlight != findMatchHighlight
            || viewportLeftMaterialisedWindow
        else {
            return
        }
        coordinator.appliedFindMatchHighlightSpan = EditorFindMatchHighlight.apply(
            findMatchHighlight,
            visibleRange: visibleRange,
            previouslyDecorated: coordinator.appliedFindMatchHighlightSpan,
            to: textStorage
        )
        coordinator.appliedFindMatchHighlightMaterialisation = findMatchHighlight == nil
            ? nil
            : EditorFindMatchHighlight.materialisationRange(
                for: visibleRange,
                storageLength: textStorage.length
            )
        coordinator.appliedFindMatchHighlight = findMatchHighlight
        coordinator.appliedFindMatchHighlightDocumentIdentity = documentIdentity
        textView.needsDisplay = true
    }
}

@MainActor
extension MarkdownTextViewCoordinator {
    /// Keeps the bounded clear span in the text storage's coordinate space as edits move marker
    /// attributes. Without this, a large insertion before a decorated match shifts the marker but
    /// leaves the recorded `NSRange` behind, so closing find can permanently strand decoration.
    func trackFindHighlightEdits(in textStorage: NSTextStorage) {
        guard findHighlightStorage !== textStorage else { return }
        findHighlightEditObserver = nil
        findHighlightStorage = textStorage
        findHighlightEditObserver = CoordinatorNotificationObserver(
            NotificationCenter.default.addObserver(
                forName: NSTextStorage.didProcessEditingNotification,
                object: textStorage,
                queue: .main
            ) { [weak self] notification in
                guard let textStorage = notification.object as? NSTextStorage,
                      textStorage.editedMask.contains(.editedCharacters)
                else {
                    return
                }
                let editedRange = textStorage.editedRange
                let changeInLength = textStorage.changeInLength
                let storageLength = textStorage.length
                MainActor.assumeIsolated { [weak self] in
                    self?.findHighlightTextDidChange(
                        editedRange: editedRange,
                        changeInLength: changeInLength,
                        storageLength: storageLength
                    )
                }
            }
        )
    }

    private func findHighlightTextDidChange(
        editedRange: NSRange,
        changeInLength: Int,
        storageLength: Int
    ) {
        appliedFindMatchHighlightSpan = appliedFindMatchHighlightSpan.flatMap {
            EditorFindMatchHighlight.range(
                $0,
                afterEditing: editedRange,
                changeInLength: changeInLength,
                storageLength: storageLength
            )
        }
        appliedFindMatchHighlightMaterialisation = appliedFindMatchHighlightMaterialisation.flatMap {
            EditorFindMatchHighlight.range(
                $0,
                afterEditing: editedRange,
                changeInLength: changeInLength,
                storageLength: storageLength
            )
        }
    }
}
