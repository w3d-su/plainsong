import Foundation
import MarkdownCore
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct IOSImagePhotoPicker: UIViewControllerRepresentable {
    let onResults: ([PHPickerResult]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.selectionLimit = 1
        configuration.filter = .images
        // Keep the original HEIC payload. This lane transcodes and then checks the PNG bytes.
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_: PHPickerViewController, context _: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onResults: onResults)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onResults: ([PHPickerResult]) -> Void
        private var delivered = false

        init(onResults: @escaping ([PHPickerResult]) -> Void) {
            self.onResults = onResults
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard !delivered else { return }
            delivered = true
            onResults(results)
            picker.dismiss(animated: true)
        }
    }
}

struct IOSImageFilePicker: UIViewControllerRepresentable {
    let onURLs: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: Self.contentTypes, asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_: UIDocumentPickerViewController, context _: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onURLs: onURLs)
    }

    private static let contentTypes: [UTType] = [.png, .jpeg, .gif, .webP, .heic, .heif]

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onURLs: ([URL]) -> Void
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

enum IOSImagePhotoPayloadLoader {
    static func load(_ result: PHPickerResult) async -> Result<IOSImagePickedPayload, IOSImagePickFailure> {
        let provider = result.itemProvider
        guard let identifier = preferredIdentifier(in: provider) else {
            return .failure(.unsupportedType)
        }
        do {
            let data = try await dataRepresentation(provider, identifier: identifier)
            return .success(
                IOSImagePickedPayload(
                    bytes: data,
                    contentType: mimeType(for: identifier),
                    preferredFilename: filename(provider, identifier: identifier)
                )
            )
        } catch {
            return .failure(.unavailable)
        }
    }

    private static func preferredIdentifier(in provider: NSItemProvider) -> String? {
        let registered = provider.registeredTypeIdentifiers
        let preferred = [
            UTType.heic.identifier,
            UTType.heif.identifier,
            UTType.png.identifier,
            UTType.jpeg.identifier,
            UTType.gif.identifier,
            UTType.webP.identifier,
        ]
        if let match = preferred.first(where: registered.contains) {
            return match
        }
        if registered.contains(UTType.image.identifier) {
            return UTType.image.identifier
        }
        return nil
    }

    private static func dataRepresentation(_ provider: NSItemProvider, identifier: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let box = ResumeOnce()
            provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, _ in
                box.resume {
                    if let data {
                        continuation.resume(returning: data)
                    } else {
                        continuation.resume(throwing: CocoaError(.fileReadUnknown))
                    }
                }
            }
        }
    }

    private static func mimeType(for identifier: String) -> String {
        UTType(identifier)?.preferredMIMEType ?? identifier
    }

    private static func filename(_ provider: NSItemProvider, identifier: String) -> String {
        let suggested = provider.suggestedName ?? "image"
        let leaf = IOSImageFilename.leaf(suggested)
        if !(leaf as NSString).pathExtension.isEmpty {
            return leaf
        }
        let ext = UTType(identifier)?.preferredFilenameExtension ?? "img"
        return "\(leaf).\(ext)"
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func resume(_ body: () -> Void) {
        lock.lock()
        if resumed {
            lock.unlock()
            return
        }
        resumed = true
        lock.unlock()
        body()
    }
}

enum IOSImagePickedFileBytes {
    /// Reads the document picker's temporary copy. It does not write the workspace asset.
    static func load(url: URL) async -> Result<IOSImagePickedPayload, IOSImagePickFailure> {
        await Task.detached {
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               Int64(size) > MarkdownImageAssetPolicy.maximumFileSizeBytes
            {
                return .failure(.tooLarge)
            }
            do {
                let bytes = try Data(contentsOf: url)
                let ext = url.pathExtension
                let mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? ""
                return .success(
                    IOSImagePickedPayload(
                        bytes: bytes,
                        contentType: mime,
                        preferredFilename: url.lastPathComponent
                    )
                )
            } catch {
                return .failure(.unavailable)
            }
        }.value
    }
}
