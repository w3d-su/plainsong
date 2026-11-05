import MarkdownCore
import SwiftUI

/// Header row: document name, dirty indicator, kind badge, saving spinner.
/// Read-only/conflict/unavailable visibility comes from the deduplicated
/// chrome snapshot; actions stay with the facade.
struct IOSDocumentStatusChrome: View {
    let chrome: IOSShellChromeSnapshot

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(chrome.documentTitle)
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .accessibilityIdentifier("plainsong.ios.editor.fileName")
                        .accessibilityLabel(fileAccessibilityLabel)
                        .accessibilityAddTraits(.isHeader)

                    if chrome.isDirty {
                        Circle()
                            .fill(.orange)
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                    }
                }

                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let statistics = chrome.statistics {
                    Text(IOSDocumentStatisticsPresentation.counts(statistics))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                        .accessibilityLabel(IOSDocumentStatisticsPresentation.accessibilitySummary(statistics))
                        .accessibilityIdentifier("plainsong.ios.editor.statistics")
                }
            }

            Spacer(minLength: 8)

            if !chrome.editorCanWrite, chrome.status == .ready {
                Text("Read Only")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
            }

            if let kind = chrome.documentKind {
                Text(kind == .mdx ? "MDX" : "Markdown")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
            }

            if chrome.isSaving {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Saving")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var fileAccessibilityLabel: String {
        chrome.isDirty
            ? "Current file, \(chrome.documentTitle), edited"
            : "Current file, \(chrome.documentTitle)"
    }

    private var statusLine: String {
        switch chrome.status {
        case .noDocument: "No file"
        case .opening: "Opening…"
        case .ready: chrome.isDirty ? "Edited" : "Saved"
        case .conflict: "Conflict"
        case .unavailable: "Unavailable"
        case .closed: "Closed"
        }
    }
}

/// Banners for non-ready document states. Buttons delegate to the facade;
/// "Save a Copy" is offered only when composition supplies the destination
/// flow (`resolveConflictCopy`), since it needs a picker + lease the shell
/// cannot derive (wiring request W14).
struct IOSDocumentStateBanner: View {
    let chrome: IOSShellChromeSnapshot
    let scene: IOSShellSceneState

    var body: some View {
        switch chrome.status {
        case .opening:
            banner(tint: .blue, showsActions: false) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Opening")
                Text("Opening document…")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } actions: {
                EmptyView()
            }
        case .conflict:
            banner(tint: .orange) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("File changed outside this editor")
                        .font(.callout.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = chrome.statusDetail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } actions: {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        bannerButton("Reload", hint: "Replace editor contents with the file on disk") {
                            scene.resolveExternal(.reload)
                        }
                        if let copy = scene.surfaces.resolveConflictCopy {
                            bannerButton("Save a Copy", action: copy)
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        bannerButton("Reload", hint: "Replace editor contents with the file on disk") {
                            scene.resolveExternal(.reload)
                        }
                        if let copy = scene.surfaces.resolveConflictCopy {
                            bannerButton("Save a Copy", action: copy)
                        }
                    }
                }
            }
        case .unavailable:
            banner(tint: .red) {
                Image(systemName: "exclamationmark.octagon")
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Document unavailable")
                        .font(.callout.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = chrome.statusDetail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } actions: {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        if scene.surfaces.reselectUnavailableWorkspace != nil {
                            bannerButton("Choose File or Folder Again") {
                                scene.reselectUnavailableDocument()
                            }
                            .accessibilityIdentifier("plainsong.ios.document.choose-again")
                        }
                        if let copy = scene.surfaces.resolveConflictCopy {
                            bannerButton(
                                "Save a Copy",
                                hint: "Save the retained text to a different folder without closing this document",
                                action: copy
                            )
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        if scene.surfaces.reselectUnavailableWorkspace != nil {
                            bannerButton("Choose File or Folder Again") {
                                scene.reselectUnavailableDocument()
                            }
                            .accessibilityIdentifier("plainsong.ios.document.choose-again")
                        }
                        if let copy = scene.surfaces.resolveConflictCopy {
                            bannerButton(
                                "Save a Copy",
                                hint: "Save the retained text to a different folder without closing this document",
                                action: copy
                            )
                        }
                    }
                }
            }
        case .ready, .noDocument, .closed:
            EmptyView()
        }
    }

    private func banner(
        tint: Color,
        showsActions: Bool = true,
        @ViewBuilder message: () -> some View,
        @ViewBuilder actions: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                message()
                Spacer(minLength: 0)
            }
            if showsActions {
                actions()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.16))
        .accessibilityElement(children: .contain)
    }

    private func bannerButton(
        _ title: String,
        hint: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
            .fixedSize(horizontal: true, vertical: false)
            .frame(minHeight: 44)
            .modifier(BannerHint(hint: hint))
    }
}

private struct BannerHint: ViewModifier {
    let hint: String?

    func body(content: Content) -> some View {
        if let hint, !hint.isEmpty {
            content.accessibilityHint(hint)
        } else {
            content
        }
    }
}

/// Empty document state for the detail column.
struct IOSEmptyDocumentView: View {
    let hasWorkspace: Bool

    var body: some View {
        ContentUnavailableView {
            Label("No File Open", systemImage: "doc.text.magnifyingglass")
        } description: {
            Text(hasWorkspace ? "Choose a file from the workspace." : "Open a file or folder to begin.")
        }
    }
}

enum IOSDocumentStatisticsPresentation {
    static func counts(_ statistics: TextStatistics) -> String {
        "\(statistics.lineCount) lines · \(statistics.wordCount) words · \(statistics.characterCount) characters"
    }

    static func accessibilitySummary(_ statistics: TextStatistics) -> String {
        "\(statistics.lineCount) lines, \(statistics.wordCount) words, \(statistics.characterCount) characters"
    }
}
