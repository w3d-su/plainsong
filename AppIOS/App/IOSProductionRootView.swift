import SwiftUI
import UIKit

/// The scene owns one runtime. SwiftUI body/layout updates cannot reconstruct
/// the editor, document store, access service, or web view.
struct IOSProductionRootView: View {
    @StateObject private var launch = IOSProductionLaunch()

    var body: some View {
        if let runtime = launch.runtime {
            IOSProductionSceneView(runtime: runtime)
        } else {
            ContentUnavailableView {
                Label("Couldn't Start Plainsong", systemImage: "exclamationmark.triangle")
            } description: {
                Text(launch.failure ?? "The editor is unavailable.")
            }
        }
    }
}

@MainActor
private final class IOSProductionLaunch: ObservableObject {
    let runtime: IOSProductionRuntime?
    let failure: String?

    init() {
        do {
            runtime = try IOSProductionComposition.makeProduction()
            failure = nil
        } catch {
            runtime = nil
            failure = "The editing services could not be created. Close and reopen the app."
        }
    }
}

private struct IOSProductionSceneView: View {
    @ObservedObject var runtime: IOSProductionRuntime
    @ObservedObject var authoring: IOSAuthoringController
    @Environment(\.scenePhase) private var scenePhase

    init(runtime: IOSProductionRuntime) {
        self.runtime = runtime
        _authoring = ObservedObject(wrappedValue: runtime.authoring)
    }

    var body: some View {
        IOSShellRootView(scene: runtime.scene)
            .confirmationDialog("Open", isPresented: $runtime.showOpenChoices, titleVisibility: .visible) {
                Button("Open Markdown File") { runtime.requestPicker(scope: .singleFile) }
                Button("Open Folder") { runtime.requestPicker(scope: .directory) }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(item: $runtime.pickerRequest) { request in
                IOSProductionDocumentPicker(request: request) { urls in
                    runtime.completePicker(request, urls: urls)
                }
            }
            .sheet(item: $authoring.linkDraft) { draft in
                NavigationStack {
                    IOSAuthoringLinkSheet(controller: authoring, editor: runtime.editor, draft: draft)
                        .padding()
                        .navigationTitle("Insert Link")
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Cancel") { authoring.linkDraft = nil }
                            }
                        }
                }
                .presentationDetents([.medium])
            }
            .onAppear { runtime.startObserving() }
            .onDisappear { runtime.stopObserving() }
            .onChange(of: scenePhase) { _, phase in runtime.setSceneActive(phase == .active) }
            .onOpenURL { url in Task { await runtime.openURL(url) } }
    }
}

/// Open in place. Scope lifetime, bookmarks and coordinated I/O belong to the
/// existing access service/UIDocument, rather than this presentation adapter.
struct IOSProductionDocumentPicker: UIViewControllerRepresentable {
    let request: IOSProductionPickerRequest
    let onURLs: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: request.contentTypes, asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_: UIDocumentPickerViewController, context _: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onURLs: onURLs)
    }

    @MainActor
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onURLs: ([URL]) -> Void
        private var delivered = false

        init(onURLs: @escaping ([URL]) -> Void) {
            self.onURLs = onURLs
        }

        func documentPicker(_: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            deliver(urls)
        }

        func documentPickerWasCancelled(_: UIDocumentPickerViewController) {
            deliver([])
        }

        private func deliver(_ urls: [URL]) {
            guard !delivered else { return }
            delivered = true
            onURLs(urls)
        }
    }
}
