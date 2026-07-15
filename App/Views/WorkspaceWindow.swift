import AppKit
import EditorKit
import MarkdownCore
import PreviewKit
import SwiftUI

/// Main window: folder sidebar + single editor/preview workspace.
struct WorkspaceWindow: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: 0) {
            WorkspaceSidebar()
                .frame(width: 220)

            Divider()

            Group {
                if appState.hasOpenDocument {
                    EditorWorkspace()
                } else {
                    EmptyEditorState()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 420)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    appState.openFile()
                } label: {
                    Label("Open", systemImage: "folder")
                }

                Button {
                    appState.save()
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .disabled(!appState.canSave)

                Button {
                    appState.cycleLayoutMode()
                } label: {
                    Label(
                        appState.layoutModeToolbarTitle,
                        systemImage: appState.layoutModeToolbarSystemImage
                    )
                }
                .disabled(!appState.hasOpenDocument)
                .help(appState.layoutModeToolbarHelp)
            }
        }
        .alert(
            appState.presentedError?.title ?? "Error",
            isPresented: errorIsPresented
        ) {
            Button("OK") {
                appState.dismissError()
            }
        } message: {
            Text(appState.presentedError?.message ?? "")
        }
        .background(
            WindowMetadataAccessor(
                representedURL: appState.currentDocument.fileURL,
                title: appState.windowTitle,
                isDocumentEdited: appState.currentDocument.isDirty
            )
        )
        .task {
            await Task.yield()
            appState.restoreLastOpenedFileIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            appState.flushAutosaveIfNeeded()
        }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { appState.presentedError != nil },
            set: { isPresented in
                if !isPresented {
                    appState.dismissError()
                }
            }
        )
    }
}

private struct EditorWorkspace: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var previewController = PreviewController()
    @StateObject private var scrollCoordinator = EditorPreviewScrollCoordinator()

    var body: some View {
        VStack(spacing: 0) {
            DocumentHeader(
                fileURL: appState.currentDocument.fileURL,
                fileKind: appState.currentDocument.fileKind,
                isDirty: appState.currentDocument.isDirty,
                isSaving: appState.isSaving
            )

            if appState.indeterminateFileWriteReconciliationPrompt != nil {
                FileWriteReconciliationBanner()
            } else if appState.missingFilePrompt != nil {
                MissingFileBanner()
            } else if appState.externalChangePrompt != nil {
                ExternalChangeBanner()
            }

            if let fallbackMessage = appState.wysiwygFallbackMessage {
                WYSIWYGFallbackBanner(message: fallbackMessage)
            }

            Divider()

            HStack(spacing: 0) {
                DocumentEditor(
                    session: appState.currentDocument,
                    isPreviewVisible: appState.isPreviewVisible,
                    usesWYSIWYGPresentation: appState.shouldUseWYSIWYGPresentation,
                    scrollCoordinator: scrollCoordinator
                )
                .environmentObject(appState)
                .clipped()
                .zIndex(0)

                if appState.isPreviewVisible {
                    Divider()

                    PreviewPane(
                        session: appState.currentDocument,
                        controller: previewController
                    )
                    .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                    .zIndex(1)
                }
            }

            Divider()

            StatusBar(
                statistics: appState.currentDocument.statistics,
                fileKind: appState.currentDocument.fileKind
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: configurePreviewCallbacks)
    }

    private func configurePreviewCallbacks() {
        scrollCoordinator.connect(previewController: previewController)

        previewController.onPreviewScrolled = { line in
            guard appState.preferences.typewriterSyncEnabled else { return }
            scrollCoordinator.previewScrolled(to: line)
        }
        previewController.onCheckboxToggled = { line, checked, version in
            appState.setTaskCheckbox(line: line, checked: checked, version: version)
        }
        previewController.onLinkClicked = { href in
            appState.openPreviewLink(href)
        }
    }
}

private struct DocumentHeader: View {
    let fileURL: URL?
    let fileKind: FileKind
    let isDirty: Bool
    let isSaving: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(fileURL?.lastPathComponent ?? "Untitled")
                        .font(.headline)
                        .lineLimit(1)

                    if isDirty {
                        Circle()
                            .fill(.orange)
                            .frame(width: 7, height: 7)
                            .accessibilityLabel("Edited")
                    }
                }

                Text(fileURL?.path ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(fileKind.displayName)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary, in: Capsule())

            if isSaving {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

private struct ExternalChangeBanner: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)

            Text("File changed on disk:")
                .font(.callout.weight(.medium))

            Button("Reload") {
                appState.reloadExternallyChangedFile()
            }

            Button("Keep mine") {
                appState.keepMineForExternallyChangedFile()
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.yellow.opacity(0.16))
    }
}

private struct WYSIWYGFallbackBanner: View {
    @EnvironmentObject private var appState: AppState
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wand.and.stars")
                .foregroundStyle(.secondary)

            Text(message)
                .font(.callout)
                .lineLimit(2)

            Spacer()

            Button("Dismiss") {
                appState.dismissWYSIWYGFallbackMessage()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.quaternary)
    }
}

private struct DocumentEditor: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var session: DocumentSession
    let isPreviewVisible: Bool
    let usesWYSIWYGPresentation: Bool
    let scrollCoordinator: EditorPreviewScrollCoordinator

    var body: some View {
        let editorBinding = appState.editorDocumentBinding(for: session)
        let presentation = EditorPresentationPolicy.resolve(
            usesWYSIWYGPresentation: usesWYSIWYGPresentation
        )

        MarkdownEditorView(
            text: editorBinding.text,
            fileKind: session.fileKind,
            fontName: appState.preferences.editorFontName,
            fontSize: CGFloat(appState.preferences.editorFontSize),
            editorTheme: appState.preferences.editorTheme,
            appearanceID: appState.preferences.editorAppearanceID,
            showsLineNumbers: appState.preferences.showsLineNumbers,
            focusRequestID: appState.editorFocusRequestID,
            documentIdentity: appState.activeEditorDocumentIdentity,
            documentBindingID: editorBinding.id,
            onDocumentBindingLifecycle: editorBinding.onLifecycle,
            documentSourceContract: editorBinding.sourceContract,
            navigationCommand: appState.editorNavigationCommand,
            scrollProxy: scrollCoordinator.editorProxy,
            completionWorkspace: appState.completionWorkspace,
            imageAssetInserter: appState.editorImageAssetInserter,
            imageAssetContextID: appState.sessionStateURL(for: session)?.path(percentEncoded: false),
            _developmentPresentation: presentation,
            _developmentImageThumbnails: appState.editorImageThumbnailConfiguration(
                for: session,
                presentation: presentation
            ),
            onWYSIWYGMechanismFailure: { reason in
                appState.handleWYSIWYGMechanismFailure(reason)
            }
        )
        .onAppear {
            scrollCoordinator
                .setEditorScrollForwardingEnabled(isPreviewVisible && appState.preferences.typewriterSyncEnabled)
        }
        .onChange(of: isPreviewVisible) { _, isVisible in
            scrollCoordinator.setEditorScrollForwardingEnabled(isVisible && appState.preferences.typewriterSyncEnabled)
        }
        .onChange(of: appState.preferences.typewriterSyncEnabled) { _, isEnabled in
            scrollCoordinator.setEditorScrollForwardingEnabled(isPreviewVisible && isEnabled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum EditorPresentationPolicy {
    static func resolve(
        usesWYSIWYGPresentation: Bool
    ) -> MarkdownEditorDevelopmentPresentation {
        usesWYSIWYGPresentation ? .inlineFoldRevealWithLinkFolding : .source
    }
}

private struct PreviewPane: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var session: DocumentSession
    @ObservedObject var controller: PreviewController

    var body: some View {
        GeometryReader { proxy in
            MarkdownPreviewWebView(controller: controller)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .onAppear {
            controller.setWorkspaceAssetRoot(appState.previewAssetRootURL)
            controller.setTheme(appState.preferences.previewTheme.rawValue)
            controller.setAllowsRemoteImages(appState.preferences.allowsRemoteImages)
            controller.render(session.currentTextChange)
        }
        .onChange(of: appState.previewAssetRootURL) { _, rootURL in
            controller.setWorkspaceAssetRoot(rootURL)
            controller.render(session.currentTextChange)
        }
        .onChange(of: appState.preferences.previewTheme) { _, theme in
            controller.setTheme(theme.rawValue)
        }
        .onChange(of: appState.preferences.allowsRemoteImages) { _, allowsRemoteImages in
            controller.setAllowsRemoteImages(allowsRemoteImages)
        }
        .task(id: ObjectIdentifier(session)) {
            controller.setWorkspaceAssetRoot(appState.previewAssetRootURL)
            controller.setTheme(appState.preferences.previewTheme.rawValue)
            controller.setAllowsRemoteImages(appState.preferences.allowsRemoteImages)
            await controller.observe(session)
        }
    }
}

private struct EmptyEditorState: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)

            Text("No File Open")
                .font(.title2.weight(.semibold))

            Button {
                appState.openFile()
            } label: {
                Label("Open...", systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct StatusBar: View {
    let statistics: TextStatistics
    let fileKind: FileKind

    var body: some View {
        HStack(spacing: 12) {
            Text("\(statistics.lineCount) lines")
            Text("\(statistics.wordCount) words")
            Text("\(statistics.characterCount) characters")

            Spacer()

            Text(fileKind.displayName)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

private struct WindowMetadataAccessor: NSViewRepresentable {
    let representedURL: URL?
    let title: String
    let isDocumentEdited: Bool

    func makeNSView(context _: Context) -> MetadataView {
        let view = MetadataView()
        view.applyMetadata = applyMetadata(to:)
        return view
    }

    func updateNSView(_ nsView: MetadataView, context _: Context) {
        nsView.applyMetadata = applyMetadata(to:)
        nsView.applyMetadataLater()
    }

    private func applyMetadata(to window: NSWindow?) {
        guard let window else { return }
        window.representedURL = representedURL
        window.title = title
        window.isDocumentEdited = isDocumentEdited
    }

    final class MetadataView: NSView {
        var applyMetadata: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyMetadataLater()
        }

        func applyMetadataLater() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                applyMetadata?(window)
            }
        }
    }
}

private extension FileKind {
    var displayName: String {
        switch self {
        case .markdown:
            "Markdown"
        case .mdx:
            "MDX"
        }
    }
}

#Preview {
    WorkspaceWindow()
        .environmentObject(AppState())
}
