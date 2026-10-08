import AppKit
import EditorKit
import MarkdownCore
import PreviewKit
import SwiftUI

/// Document column: jump bar, notices, Find bar, editor (+ preview), status bar.
struct EditorWorkspace: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var previewController = PreviewController()
    @StateObject private var scrollCoordinator = EditorPreviewScrollCoordinator()

    var body: some View {
        VStack(spacing: 0) {
            DocumentJumpBar(
                rootURL: appState.workspaceRootURL,
                fileURL: appState.currentDocument.fileURL,
                fileKind: appState.currentDocument.fileKind,
                isSaving: appState.isSaving,
                isDirty: appState.currentDocument.isDirty,
                workspaceTree: { appState.workspaceTree },
                openNode: { appState.selectWorkspaceNode(id: $0) }
            )

            if appState.workspaceMutationRecoveryBannerPlacement == .editor {
                WorkspaceMutationRecoveryBanner()
            } else if appState.indeterminateFileWriteReconciliationPrompt != nil {
                FileWriteReconciliationBanner()
            } else if appState.missingFilePrompt != nil {
                MissingFileBanner()
            } else if appState.externalChangePrompt != nil {
                ExternalChangeBanner()
            }

            if let fallbackMessage = appState.wysiwygFallbackMessage {
                WYSIWYGFallbackBanner(message: fallbackMessage)
            }

            if appState.editorFindHost.ui.isBarVisible {
                EditorFindBar()
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
                .frame(minWidth: WorkspaceLayout.editorMinimum)
                .workspaceFrameProbe("editor")
                .clipped()
                .zIndex(0)

                if appState.isPreviewVisible {
                    Divider()

                    PreviewPane(
                        session: appState.currentDocument,
                        controller: previewController
                    )
                    .frame(minWidth: WorkspaceLayout.previewMinimum, maxWidth: .infinity, maxHeight: .infinity)
                    .workspaceFrameProbe("preview")
                    .zIndex(1)
                }
            }

            Divider()

            WorkspaceStatusBar(statistics: appState.currentDocument.statistics)
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
        previewController.onCheckboxToggled = { line, checked, version, session in
            appState.setTaskCheckbox(line: line, checked: checked, version: version, in: session)
        }
        previewController.onLinkClicked = { href in
            appState.openPreviewLink(href)
        }
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
            findMatchHighlight: appState.editorFindMatchHighlight,
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
            controller.setPresentedDocumentIdentifier(appState.activeEditorDocumentIdentity?.rawValue)
            controller.render(session.currentTextChange, for: session)
        }
        .onChange(of: appState.previewAssetRootURL) { _, rootURL in
            controller.setWorkspaceAssetRoot(rootURL)
            controller.render(session.currentTextChange, for: session)
        }
        .onChange(of: appState.activeEditorDocumentIdentity) { _, identity in
            controller.setPresentedDocumentIdentifier(identity?.rawValue)
            controller.render(session.currentTextChange, for: session)
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
            controller.setPresentedDocumentIdentifier(appState.activeEditorDocumentIdentity?.rawValue)
            await controller.observe(session)
        }
    }
}
