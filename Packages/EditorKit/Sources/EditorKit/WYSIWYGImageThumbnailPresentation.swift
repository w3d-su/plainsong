import AppKit

/// Attribute carried only by raw backing ranges that currently have an image projection.
/// The object replacement character and attachment remain confined to the paragraph copy.
final class WYSIWYGImagePresentationMarker: NSObject {
    static let attribute = NSAttributedString.Key("app.plainsong.wysiwyg.imagePresentation")

    enum VisualState: Equatable {
        case loading
        case failed
        case ready(
            resolvedWorkspaceRelativePath: String,
            modificationDate: Date,
            pixelWidth: Int,
            pixelHeight: Int,
            pngByteCount: Int
        )
    }

    struct Signature: Equatable {
        let generation: UInt64
        let sourceRange: NSRange
        let altText: String
        let canvasSize: NSSize
        let visualState: VisualState
    }

    let generation: UInt64
    let sourceRange: NSRange
    let source: String
    let altText: String
    let canvasSize: NSSize
    let contentRect: NSRect
    let visualState: VisualState
    let image: NSImage
    let lineHeightFont: NSFont

    var signature: Signature {
        Signature(
            generation: generation,
            sourceRange: sourceRange,
            altText: altText,
            canvasSize: canvasSize,
            visualState: visualState
        )
    }

    var resolvedWorkspaceRelativePath: String? {
        guard case let .ready(path, _, _, _, _) = visualState else {
            return nil
        }
        return path
    }

    init(
        generation: UInt64,
        sourceRange: NSRange,
        source: String,
        altText: String,
        canvasSize: NSSize,
        outcome: EditorImageThumbnailOutcome?
    ) {
        self.generation = generation
        self.sourceRange = sourceRange
        self.source = source
        self.altText = altText
        self.canvasSize = canvasSize

        switch outcome {
        case let .ready(thumbnail):
            let proposedContentRect = Self.contentRect(
                pixelWidth: thumbnail.pixelWidth,
                pixelHeight: thumbnail.pixelHeight,
                canvasSize: canvasSize
            )
            if let thumbnailImage = NSImage(data: thumbnail.pngData),
               thumbnailImage.isValid,
               !proposedContentRect.isEmpty
            {
                contentRect = proposedContentRect
                visualState = .ready(
                    resolvedWorkspaceRelativePath: thumbnail.resolvedWorkspaceRelativePath,
                    modificationDate: thumbnail.contentModificationDate,
                    pixelWidth: thumbnail.pixelWidth,
                    pixelHeight: thumbnail.pixelHeight,
                    pngByteCount: thumbnail.pngData.count
                )
                image = Self.makeThumbnailImage(
                    thumbnailImage,
                    contentRect: proposedContentRect,
                    canvasSize: canvasSize,
                    accessibilityDescription: altText
                )
            } else {
                contentRect = .zero
                visualState = .failed
                image = Self.makePlaceholderImage(
                    altText: altText,
                    canvasSize: canvasSize,
                    accessibilityDescription: altText
                )
            }

        case .failed:
            contentRect = .zero
            visualState = .failed
            image = Self.makePlaceholderImage(
                altText: altText,
                canvasSize: canvasSize,
                accessibilityDescription: altText
            )

        case .none:
            contentRect = .zero
            visualState = .loading
            image = Self.makePlaceholderImage(
                altText: altText,
                canvasSize: canvasSize,
                accessibilityDescription: altText
            )

        case .stayRaw:
            preconditionFailure("Stay-raw outcomes must never receive a presentation marker")
        }

        lineHeightFont = Self.makeLineHeightFont(for: canvasSize.height)
        super.init()
    }

    func makeAttachment() -> NSTextAttachment {
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: -4, width: canvasSize.width, height: canvasSize.height)
        attachment.allowsTextAttachmentView = false
        return attachment
    }
}

enum WYSIWYGImagePresentationMetrics {
    static let maximumDisplayWidth: CGFloat = 360
    static let maximumDisplayHeight: CGFloat = 300
    static let interImageSpacing: CGFloat = 8

    static func canvasSize(availableWidth: CGFloat, imageCountInParagraph: Int) -> NSSize {
        let count = max(imageCountInParagraph, 1)
        let finiteWidth = availableWidth.isFinite ? availableWidth : maximumDisplayWidth
        let boundedAvailableWidth = max(finiteWidth, 1)
        let totalSpacing = interImageSpacing * CGFloat(max(count - 1, 0))
        let perImageWidth = max((boundedAvailableWidth - totalSpacing) / CGFloat(count), 1)
        let width = floor(min(perImageWidth, maximumDisplayWidth))
        let height = floor(min(max(width * 2 / 3, 24), maximumDisplayHeight))
        return NSSize(width: max(width, 1), height: max(height, 1))
    }
}

private extension WYSIWYGImagePresentationMarker {
    static func contentRect(pixelWidth: Int, pixelHeight: Int, canvasSize: NSSize) -> NSRect {
        guard pixelWidth > 0, pixelHeight > 0 else {
            return .zero
        }

        let horizontalInset: CGFloat = 8
        let verticalInset: CGFloat = 8
        let availableWidth = max(canvasSize.width - horizontalInset * 2, 1)
        let availableHeight = max(canvasSize.height - verticalInset * 2, 1)
        let scale = min(
            availableWidth / CGFloat(pixelWidth),
            availableHeight / CGFloat(pixelHeight)
        )
        let size = NSSize(
            width: max(floor(CGFloat(pixelWidth) * scale), 1),
            height: max(floor(CGFloat(pixelHeight) * scale), 1)
        )
        return NSRect(
            x: floor((canvasSize.width - size.width) / 2),
            y: floor((canvasSize.height - size.height) / 2),
            width: size.width,
            height: size.height
        )
    }

    static func makeThumbnailImage(
        _ thumbnail: NSImage,
        contentRect: NSRect,
        canvasSize: NSSize,
        accessibilityDescription: String
    ) -> NSImage {
        let image = NSImage(size: canvasSize, flipped: false) { bounds in
            drawCanvas(in: bounds)
            let context = NSGraphicsContext.current
            let previousInterpolation = context?.imageInterpolation
            context?.imageInterpolation = .high
            thumbnail.draw(
                in: contentRect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: nil
            )
            if let previousInterpolation {
                context?.imageInterpolation = previousInterpolation
            }
            return true
        }
        image.accessibilityDescription = accessibilityDescription
        return image
    }

    static func makePlaceholderImage(
        altText: String,
        canvasSize: NSSize,
        accessibilityDescription: String
    ) -> NSImage {
        let image = NSImage(size: canvasSize, flipped: false) { bounds in
            drawCanvas(in: bounds)

            let label = altText.isEmpty ? "Image" : altText
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let measured = (label as NSString).size(withAttributes: attributes)
            let chipHeight = min(max(measured.height + 10, 24), max(bounds.height - 12, 1))
            let chipWidth = min(max(measured.width + 20, 64), max(bounds.width - 12, 1))
            let chipRect = NSRect(
                x: floor((bounds.width - chipWidth) / 2),
                y: floor((bounds.height - chipHeight) / 2),
                width: chipWidth,
                height: chipHeight
            )
            NSColor.controlBackgroundColor.setFill()
            NSBezierPath(roundedRect: chipRect, xRadius: 7, yRadius: 7).fill()

            let textRect = chipRect.insetBy(dx: 10, dy: 5)
            (label as NSString).draw(
                with: textRect,
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: attributes
            )
            return true
        }
        image.accessibilityDescription = accessibilityDescription
        return image
    }

    static func drawCanvas(in bounds: NSRect) {
        NSColor.quaternaryLabelColor.withAlphaComponent(0.08).setFill()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
        path.fill()
        NSColor.separatorColor.withAlphaComponent(0.55).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    static func makeLineHeightFont(for targetHeight: CGFloat) -> NSFont {
        var pointSize = max(targetHeight, 1)
        var font = NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
        for _ in 0 ..< 4 {
            let lineHeight = font.ascender - font.descender + font.leading
            guard lineHeight > 0 else {
                break
            }
            pointSize *= targetHeight / lineHeight
            font = NSFont.monospacedSystemFont(ofSize: max(pointSize, 1), weight: .regular)
        }
        return font
    }
}
