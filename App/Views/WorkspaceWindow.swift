import AppKit
import EditorKit
import MarkdownCore
import PreviewKit
import SwiftUI

/// Main window: sidebar placeholder + single-file editor.
struct WorkspaceWindow: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationSplitView {
            SidebarPlaceholder(fileURL: appState.currentDocument.fileURL)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            Group {
                if appState.hasOpenDocument {
                    EditorWorkspace()
                } else {
                    EmptyEditorState()
                }
            }
        }
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
                    appState.togglePreview()
                } label: {
                    Label(
                        appState.isPreviewVisible ? "Hide Preview" : "Show Preview",
                        systemImage: "sidebar.right"
                    )
                }
                .disabled(!appState.hasOpenDocument)
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

private struct SidebarPlaceholder: View {
    let fileURL: URL?

    var body: some View {
        List {
            Section("Workspace") {
                Label("No folder open", systemImage: "sidebar.left")
                    .foregroundStyle(.secondary)
            }

            Section("File") {
                if let fileURL {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(fileURL.lastPathComponent)
                            .lineLimit(1)
                        Text(fileURL.deletingLastPathComponent().path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .padding(.vertical, 2)
                } else {
                    Text("No file open")
                        .foregroundStyle(.secondary)
                }
            }
        }
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

            Divider()

            HStack(spacing: 0) {
                DocumentEditor(
                    session: appState.currentDocument,
                    isPreviewVisible: appState.isPreviewVisible,
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
            scrollCoordinator.previewScrolled(to: line)
        }
        previewController.onCheckboxToggled = { line, checked in
            appState.setTaskCheckbox(line: line, checked: checked)
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

private struct DocumentEditor: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var session: DocumentSession
    let isPreviewVisible: Bool
    let scrollCoordinator: EditorPreviewScrollCoordinator

    var body: some View {
        MarkdownEditorView(
            text: Binding(
                get: { session.text },
                set: { newText in
                    appState.replaceDocumentText(newText)
                }
            ),
            fileKind: session.fileKind,
            showsLineNumbers: true
        )
        .background(
            EditorScrollBridge(proxy: scrollCoordinator.editorProxy) { line in
                guard isPreviewVisible else { return }
                scrollCoordinator.editorScrolled(to: line)
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PreviewPane: View {
    @ObservedObject var session: DocumentSession
    @ObservedObject var controller: PreviewController

    var body: some View {
        GeometryReader { proxy in
            MarkdownPreviewWebView(controller: controller)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .onAppear {
            controller.render(session.currentTextChange)
        }
        .task(id: ObjectIdentifier(session)) {
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
                Label("Open File", systemImage: "folder")
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
