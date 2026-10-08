import PhotosUI
import SwiftUI

/// Entry points for one image. Lane 10 places this view; lane 13 supplies the real writer and editor.
struct IOSImageInsertionView: View {
    @ObservedObject var session: IOSImageInsertionSession

    @State private var showPhotos = false
    @State private var showFiles = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button("Photos") { presentPhotos() }
                    .accessibilityLabel("Insert photo from library")
                    .disabled(isBusy)
                Button("Files") { presentFiles() }
                    .accessibilityLabel("Insert image from Files")
                    .disabled(isBusy)
            }
            status
        }
        .sheet(isPresented: $showPhotos, onDismiss: session.pickerDismissed) {
            IOSImagePhotoPicker { results in
                handlePhotos(results)
                showPhotos = false
            }
        }
        .sheet(isPresented: $showFiles, onDismiss: session.pickerDismissed) {
            IOSImageFilePicker { urls in
                handleFiles(urls)
                showFiles = false
            }
        }
        .onDisappear(perform: session.teardown)
    }

    @ViewBuilder private var status: some View {
        switch session.phase {
        case .needsDirectoryGrant:
            VStack(alignment: .leading, spacing: 8) {
                Text(IOSImageInsertionMessages.needsDirectoryGrant())
                Button("Choose Folder", action: chooseFolder)
                    .accessibilityLabel("Choose folder before inserting an image")
            }
        case .importing:
            Text("Saving image…")
        case let .retained(relativePath):
            Text(IOSImageInsertionMessages.recovery(relativePath: relativePath))
        case .inserted(_, true):
            Text("Image inserted. The saved file stays in place if you undo the text.")
        case .inserted:
            Text("Image inserted.")
        case .failed:
            Text("The image was not inserted. The document was not changed.")
        case .refused:
            Text("The image was not inserted. The document was not changed.")
        case .cancelled, .idle, .picking:
            EmptyView()
        }
    }

    private var isBusy: Bool {
        if case .importing = session.phase {
            return true
        }
        return false
    }

    private func presentPhotos() {
        guard session.preparePicker() != nil else { return }
        showPhotos = true
    }

    private func presentFiles() {
        guard session.preparePicker() != nil else { return }
        showFiles = true
    }

    private func chooseFolder() {
        session.requestDirectoryGrant()
    }

    private func handlePhotos(_ results: [PHPickerResult]) {
        guard let result = results.first, let context = session.beginImport() else {
            session.pickerDismissed()
            return
        }
        Task {
            let loaded = await IOSImagePhotoPayloadLoader.load(result)
            await session.finishImport(loaded, context: context)
        }
    }

    private func handleFiles(_ urls: [URL]) {
        guard let url = urls.first, let context = session.beginImport() else {
            session.pickerDismissed()
            return
        }
        Task {
            let loaded = await IOSImagePickedFileBytes.load(url: url)
            await session.finishImport(loaded, context: context)
        }
    }
}
