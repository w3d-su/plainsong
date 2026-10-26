import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Install once with `.background(IOSConflictCopyPresenter(coordinator: copy))`.
/// The owner supplies the existing scene controller; this view creates no I/O.
struct IOSConflictCopyPresenter: View {
    @ObservedObject var coordinator: IOSConflictCopyCoordinator
    @State private var presentedDraftID: UUID?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .sheet(item: draftBinding, onDismiss: finishNamePresentation) { draft in
                IOSConflictCopyNameSheet(coordinator: coordinator, draft: draft)
                    .onAppear { presentedDraftID = draft.id }
            }
            .alert(item: noticeBinding) { notice in
                Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("OK")))
            }
    }

    private func finishNamePresentation() {
        if let id = presentedDraftID {
            coordinator.nameSheetDidDismiss(id)
        }
        presentedDraftID = nil
    }

    private var draftBinding: Binding<IOSConflictCopyDraft?> {
        Binding(get: { coordinator.draft }, set: { value in
            if value == nil, let draft = coordinator.draft {
                coordinator.cancelDraft(draft.id)
            }
        })
    }

    private var noticeBinding: Binding<IOSConflictCopyNotice?> {
        Binding(get: { coordinator.draft == nil ? coordinator.notice : nil }, set: { coordinator.notice = $0 })
    }
}

private struct IOSConflictCopyNameSheet: View {
    @ObservedObject var coordinator: IOSConflictCopyCoordinator
    let draft: IOSConflictCopyDraft
    @State private var filename: String

    init(coordinator: IOSConflictCopyCoordinator, draft: IOSConflictCopyDraft) {
        self.coordinator = coordinator
        self.draft = draft
        _filename = State(initialValue: draft.suggestedFilename)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Copy Filename") {
                    TextField("Markdown or MDX filename", text: $filename)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("plainsong.ios.conflict-copy.filename")
                    Text("A copy keeps the original conflict and recovery draft. Existing files are never replaced.")
                        .font(.footnote)
                }
                Section {
                    Button("Choose Folder and Save Copy") {
                        _ = coordinator.requestFolderPicker(draftID: draft.id, filename: filename)
                    }
                    .accessibilityIdentifier("plainsong.ios.conflict-copy.choose-folder")
                    .keyboardShortcut(.defaultAction)
                    .disabled(filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || coordinator.isSaving)
                    if coordinator.isSaving {
                        ProgressView("Saving Copy…")
                            .accessibilityIdentifier("plainsong.ios.conflict-copy.progress")
                    }
                }
            }
            .disabled(coordinator.isSaving)
            .navigationTitle("Save a Copy")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { coordinator.cancelDraft(draft.id) }
                        .disabled(coordinator.isSaving)
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .interactiveDismissDisabled(coordinator.isSaving)
        .sheet(item: pickerBinding) { request in
            IOSConflictCopyFolderPicker(
                request: request,
                onPick: { _ = coordinator.completePicker(request, urls: $0) },
                onCancel: { coordinator.cancelPicker(request.id) }
            )
        }
        .alert(item: Binding(
            get: { coordinator.validationNotice },
            set: { coordinator.validationNotice = $0 }
        )) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("OK")))
        }
    }

    private var pickerBinding: Binding<IOSConflictCopyPickerRequest?> {
        Binding(get: { coordinator.pickerRequest }, set: { value in
            if value == nil, let request = coordinator.pickerRequest {
                coordinator.cancelPicker(request.id)
            }
        })
    }
}

/// This issuance is independent of the document-opening picker. Its folder URL
/// reaches only the copy coordinator, never openPickedURL or currentGrant.
private struct IOSConflictCopyFolderPicker: UIViewControllerRepresentable {
    let request: IOSConflictCopyPickerRequest
    let onPick: ([URL]) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Delegate {
        Delegate(onPick: onPick, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_: UIDocumentPickerViewController, context _: Context) {}

    final class Delegate: NSObject, UIDocumentPickerDelegate {
        private let onPick: ([URL]) -> Void
        private let onCancel: () -> Void

        init(onPick: @escaping ([URL]) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }

        func documentPickerWasCancelled(_: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}
