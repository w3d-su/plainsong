import AppKit
import STTextView
import UniformTypeIdentifiers

@MainActor
final class MarkdownSTTextView: STTextView {
    var pasteHandler: ((MarkdownSTTextView, NSPasteboard) -> Bool)?
    var imageFileDropHandler: ((MarkdownSTTextView, [URL]) -> Bool)?

    @objc override func paste(_ sender: Any?) {
        if pasteHandler?(self, .general) == true {
            return
        }

        super.paste(sender)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if !Self.imageFileURLs(from: sender.draggingPasteboard).isEmpty {
            return imageFileDropHandler == nil ? [] : .copy
        }

        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if !Self.imageFileURLs(from: sender.draggingPasteboard).isEmpty {
            guard imageFileDropHandler != nil else { return [] }
            _ = super.draggingUpdated(sender)
            return .copy
        }

        return super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let imageURLs = Self.imageFileURLs(from: sender.draggingPasteboard)
        guard !imageURLs.isEmpty else {
            return super.performDragOperation(sender)
        }

        _ = super.draggingUpdated(sender)
        return imageFileDropHandler?(self, imageURLs) == true
    }
}

extension MarkdownSTTextView {
    static func imageAssets(from pasteboard: NSPasteboard) -> [EditorImageAsset] {
        let fileURLs = imageFileURLs(from: pasteboard)
        if !fileURLs.isEmpty {
            return fileURLs.map(EditorImageAsset.file)
        }

        if let pngData = pasteboard.data(forType: .png) ?? pasteboard.data(forType: pngPasteboardType) {
            return [.data(pngData, suggestedFilename: "image.png")]
        }

        guard let image = NSImage(pasteboard: pasteboard),
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:])
        else {
            return []
        }

        return [.data(pngData, suggestedFilename: "image.png")]
    }

    static func imageFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) ?? []

        return objects
            .compactMap { object -> URL? in
                if let url = object as? URL {
                    return url
                }
                return (object as? NSURL)?.absoluteURL
            }
            .filter(isImageFileURL)
    }

    private static func isImageFileURL(_ url: URL) -> Bool {
        guard url.isFileURL,
              let type = UTType(filenameExtension: url.pathExtension)
        else {
            return false
        }
        return type.conforms(to: .image)
    }

    private static let pngPasteboardType = NSPasteboard.PasteboardType("public.png")
}
