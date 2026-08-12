import AppKit
@testable import EditorKit
import MarkdownCore
import STTextView
import SwiftUI
import XCTest

@MainActor
enum EditorReplaceBatchSpikeSupport {
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    final class Model {
        var source: String
        var savedSource: String
        var revision = 0
        var activeWriterInstallation: EditorDocumentBindingInstallation?
        var writerActivations = 0
        var publications: [String] = []
        let bindingID = EditorDocumentBindingID()

        init(source: String) {
            self.source = source
            savedSource = source
        }

        var isDirty: Bool {
            !ExactSourceText.matches(source, savedSource)
        }

        var snapshot: EditorDocumentSourceSnapshot {
            EditorDocumentSourceSnapshot(source: source, revision: revision)
        }

        func makeContract() -> EditorDocumentSourceContract {
            EditorDocumentSourceContract(
                bindingID: bindingID,
                snapshot: { self.snapshot },
                lifecycle: { _ in },
                writer: { event in
                    switch event {
                    case let .activate(installation, base):
                        if base.revision != self.revision {
                            return .synchronize(self.snapshot)
                        }
                        self.activeWriterInstallation = installation
                        self.writerActivations += 1
                        return .activated(self.snapshot)
                    case .release:
                        return .released
                    }
                },
                pendingSource: { _ in },
                publish: { publication in
                    self.publications.append(publication.source)
                    self.source = publication.source
                    self.revision += 1
                    return .accepted(self.snapshot, sourceWasReconciled: false)
                }
            )
        }
    }

    struct Fixture {
        let window: NSWindow
        let textView: MarkdownSTTextView
        let coordinator: MarkdownTextViewCoordinator
        let model: Model
    }

    static func makeFixture(
        source: String,
        selection: NSRange = NSRange(location: 0, length: 0),
        enableWYSIWYG: Bool = false
    ) throws -> Fixture {
        let model = Model(source: source)
        let contract = model.makeContract()
        let frame = NSRect(x: 0, y: 0, width: 640, height: 240)
        let scrollView = MarkdownSTTextView.scrollableTextView(frame: frame)
        let textView = try XCTUnwrap(scrollView.documentView as? MarkdownSTTextView)
        textView.isEditable = true
        textView.isSelectable = true
        textView.font = MarkdownSyntaxHighlighter.defaultFont
        textView.text = source
        textView.textSelection = selection
        if enableWYSIWYG {
            XCTAssertTrue(textView.setWYSIWYGZeroWidthFoldingEnabled(true))
        }

        let textBinding = Binding(
            get: { model.source },
            set: { model.source = $0 }
        )
        let representable = MarkdownTextView(
            text: textBinding,
            styledText: nil,
            selection: .constant(selection),
            showsLineNumbers: false,
            documentIdentity: EditorDocumentIdentity(rawValue: "replace-r0"),
            documentBindingID: model.bindingID,
            documentSourceContract: contract,
            isWYSIWYGZeroWidthFoldingEnabled: enableWYSIWYG
        )
        let coordinator = representable.makeCoordinator()
        textView.textDelegate = coordinator
        let window = EditorFindControllerTestSupport.registerWindowForTeardown(
            NSWindow(
                contentRect: frame,
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
        )
        window.contentView = scrollView
        window.makeKeyAndOrderFront(nil)
        representable.updateRepresentedTextView(scrollView, coordinator: coordinator)
        _ = window.makeFirstResponder(textView)
        textView.undoManager?.removeAllActions()
        return Fixture(
            window: window,
            textView: textView,
            coordinator: coordinator,
            model: model
        )
    }

    static func viewText(in textView: STTextView) -> String {
        MarkdownTextView.textStorage(of: textView)?.string ?? textView.text ?? ""
    }

    static func matchRanges(
        in source: String,
        query: String,
        caseSensitivity: TextSearchCaseSensitivity = .sensitive
    ) -> [NSRange] {
        TextSearchEngine.matches(
            in: source,
            query: TextSearchQuery(pattern: query, caseSensitivity: caseSensitivity),
            limit: EditorFindLimits.engineMatchLimit
        ).map(\.range)
    }

    static func applyPresentation(
        _ source: String,
        selection: NSRange,
        revision: Int,
        to textView: STTextView
    ) {
        let highlighted = MarkdownSyntaxHighlighter().highlight(
            source,
            fileKind: .markdown,
            visibleRange: NSRange(location: 0, length: (source as NSString).length),
            developmentPresentation: .inlineFoldReveal,
            selection: selection
        )
        XCTAssertTrue(MarkdownTextView.applyHighlightedText(
            HighlightedText(
                revision: revision,
                range: highlighted.range,
                text: highlighted.text,
                foldPlan: highlighted.foldPlan
            ),
            to: textView
        ))
    }
}
