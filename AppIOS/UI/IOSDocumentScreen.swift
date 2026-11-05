import SwiftUI

/// The document column: status chrome + banners + the dual-pane container +
/// authoring toolbar + sheets. Mounted as the compact NavigationStack's pushed
/// destination or the regular-width split view's detail.
struct IOSDocumentScreen: View {
    @ObservedObject var scene: IOSShellSceneState
    @ObservedObject var router: IOSShellActionRouter
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        VStack(spacing: 0) {
            if scene.chrome.hasDocument {
                IOSDocumentStatusChrome(chrome: scene.chrome)
                if let status = scene.exportStatus {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityHidden(true)
                        Text(status)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(status)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.thinMaterial)
                }
                IOSDocumentStateBanner(chrome: scene.chrome, scene: scene)
                contentArea
            } else {
                IOSEmptyDocumentView(hasWorkspace: scene.chrome.hasWorkspace)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            if scene.chrome.hasDocument {
                ToolbarItem(placement: .principal) {
                    IOSPaneToggle(scene: scene)
                }
                IOSAuthoringToolbarItems(scene: scene, router: router)
                ToolbarItem(placement: .topBarLeading) {
                    IOSSettingsLink()
                }
            }
        }
        .sheet(item: Binding(
            get: { scene.presentation },
            set: { presentation in
                if presentation == nil {
                    // SwiftUI-driven dismissal (swipe-down) goes through the
                    // same cancel path as explicit Cancel buttons.
                    scene.dismissPresentation()
                }
            }
        )) { presentation in
            sheetContent(for: presentation)
        }
        .onAppear {
            // The document column claims the scene command route so toolbar and
            // keyboard actions reach this scene's editor. The facade validates
            // the expected binding; it is free to refuse.
            scene.claimCommandFocus()
        }
        .onDisappear {
            scene.releaseCommandFocus()
        }
    }

    private var contentArea: some View {
        GeometryReader { proxy in
            IOSEditorPreviewContainer(
                layout: scene.layout,
                editorView: scene.editorHostView,
                previewView: scene.previewHostView
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                updateLayout(width: proxy.size.width)
            }
            .onChange(of: proxy.size.width) { _, width in
                updateLayout(width: width)
            }
            .onChange(of: horizontalSizeClass) { _, _ in
                updateLayout(width: proxy.size.width)
            }
        }
    }

    private func updateLayout(width: CGFloat) {
        scene.updateLayout(
            prefersRegularWidth: horizontalSizeClass == .regular,
            contentWidth: width
        )
    }

    @ViewBuilder
    private func sheetContent(for presentation: IOSShellPresentation) -> some View {
        // The context was captured at presentation time; hosted content uses it
        // for cancel semantics and never receives a commit signal on dismiss.
        let content: AnyView? = {
            guard let context = scene.sheetContext else { return nil }
            switch presentation {
            case .frontmatter:
                return scene.surfaces.makeAuthoringPanel?(.frontmatter, context)
            case .findReplace:
                return scene.surfaces.makeAuthoringPanel?(.findReplace, context)
            case .imagePicker:
                return scene.surfaces.makeImagePicker?(context)
            case .workspaceSearch:
                return AnyView(IOSWorkspaceSearchSheet(scene: scene))
            }
        }()

        if let content {
            content
        } else {
            NavigationStack {
                ContentUnavailableView {
                    Label("Not Available Yet", systemImage: "hammer")
                } description: {
                    Text("This panel needs a provider that isn't wired in yet.")
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { scene.dismissPresentation() }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }
}
