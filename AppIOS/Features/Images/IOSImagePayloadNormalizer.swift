import Foundation
import MarkdownCore
import WorkspaceKitIOS

enum IOSImageNormalizationError: Error, Equatable, Sendable {
    case unsupportedType
    case mismatchedRepresentation
    case tooLarge

    var workspaceFailure: IOSWorkspaceFailure {
        switch self {
        case .unsupportedType, .mismatchedRepresentation:
            .unsupportedType
        case .tooLarge:
            .tooLarge
        }
    }
}

struct IOSImageNormalizedPayload: Sendable, Equatable {
    let bytes: Data
    let contentType: String
    let preferredFilename: String
}

/// Sniffs raster bytes and applies `MarkdownImageAssetPolicy` before any asset writer runs.
struct IOSImagePayloadNormalizer: Sendable {
    let transcoder: any IOSImageRasterTranscoding

    init(transcoder: any IOSImageRasterTranscoding = IOSImageIORasterTranscoder()) {
        self.transcoder = transcoder
    }

    func normalize(
        bytes: Data,
        contentType: String,
        preferredFilename: String
    ) throws -> IOSImageNormalizedPayload {
        if bytes.isEmpty {
            throw IOSImageNormalizationError.unsupportedType
        }
        let sniffed = IOSImageByteSignature.sniff(bytes)
        let declared = IOSImageDeclaredType.parse(contentType)
        switch sniffed {
        case .svg, .executable, .unknown:
            throw IOSImageNormalizationError.unsupportedType
        case .heic:
            return try transcodeHEIC(bytes, declared: declared, preferredFilename: preferredFilename)
        case let .raster(kind):
            return try accept(bytes, kind: kind, declared: declared, preferredFilename: preferredFilename)
        }
    }

    private func accept(
        _ bytes: Data,
        kind: IOSImageRasterKind,
        declared: IOSImageDeclaredType,
        preferredFilename: String
    ) throws -> IOSImageNormalizedPayload {
        guard declared.rasterKind == kind else {
            throw IOSImageNormalizationError.mismatchedRepresentation
        }
        let leaf = IOSImageFilename.leaf(preferredFilename)
        guard IOSImageFilename.extensionMatches(leaf, kind: kind) else {
            throw IOSImageNormalizationError.mismatchedRepresentation
        }
        try rejectIfLargerThanPolicy(bytes.count)
        return IOSImageNormalizedPayload(
            bytes: bytes,
            contentType: kind.mimeType,
            preferredFilename: IOSImageFilename.ensuringExtension(leaf, kind: kind)
        )
    }

    private func transcodeHEIC(
        _ bytes: Data,
        declared: IOSImageDeclaredType,
        preferredFilename: String
    ) throws -> IOSImageNormalizedPayload {
        guard declared == .heic else {
            throw IOSImageNormalizationError.mismatchedRepresentation
        }
        let leaf = IOSImageFilename.leaf(preferredFilename)
        guard IOSImageFilename.isHEICLeaf(leaf) else {
            throw IOSImageNormalizationError.mismatchedRepresentation
        }
        try rejectIfLargerThanPolicy(bytes.count)
        guard let png = transcoder.pngData(fromHEIC: bytes), IOSImageByteSignature.sniff(png) == .raster(.png) else {
            throw IOSImageNormalizationError.unsupportedType
        }
        try rejectIfLargerThanPolicy(png.count)
        return IOSImageNormalizedPayload(
            bytes: png,
            contentType: IOSImageRasterKind.png.mimeType,
            preferredFilename: IOSImageFilename.replacingExtension(leaf, with: "png")
        )
    }

    private func rejectIfLargerThanPolicy(_ count: Int) throws {
        if Int64(count) > MarkdownImageAssetPolicy.maximumFileSizeBytes {
            throw IOSImageNormalizationError.tooLarge
        }
    }
}

enum IOSImageRasterKind: Equatable, Sendable {
    case png
    case jpeg
    case gif
    case webp

    var mimeType: String {
        switch self {
        case .png: "image/png"
        case .jpeg: "image/jpeg"
        case .gif: "image/gif"
        case .webp: "image/webp"
        }
    }

    var canonicalExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        case .gif: "gif"
        case .webp: "webp"
        }
    }
}

enum IOSImageDeclaredType: Equatable, Sendable {
    case raster(IOSImageRasterKind)
    case heic
    case other

    var rasterKind: IOSImageRasterKind? {
        if case let .raster(kind) = self {
            return kind
        }
        return nil
    }

    static func parse(_ contentType: String) -> IOSImageDeclaredType {
        let token = contentType
            .split(separator: ";", maxSplits: 1)
            .first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? ""
        switch token {
        case "image/png", "public.png":
            return .raster(.png)
        case "image/jpeg", "image/jpg", "public.jpeg":
            return .raster(.jpeg)
        case "image/gif", "public.gif":
            return .raster(.gif)
        case "image/webp", "public.webp", "org.webmproject.webp":
            return .raster(.webp)
        case "image/heic", "image/heif", "public.heic", "public.heif":
            return .heic
        default:
            return .other
        }
    }
}

enum IOSImageByteSignature: Equatable, Sendable {
    case raster(IOSImageRasterKind)
    case heic
    case svg
    case executable
    case unknown

    static func sniff(_ data: Data) -> IOSImageByteSignature {
        if isExecutable(data) {
            return .executable
        }
        if isSVG(data) {
            return .svg
        }
        if hasPNG(data) {
            return .raster(.png)
        }
        if hasJPEG(data) {
            return .raster(.jpeg)
        }
        if hasGIF(data) {
            return .raster(.gif)
        }
        if hasWebP(data) {
            return .raster(.webp)
        }
        if hasHEIC(data) {
            return .heic
        }
        return .unknown
    }

    private static func hasPNG(_ data: Data) -> Bool {
        data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    private static func hasJPEG(_ data: Data) -> Bool {
        data.starts(with: [0xFF, 0xD8, 0xFF])
    }

    private static func hasGIF(_ data: Data) -> Bool {
        data.starts(with: Data("GIF87a".utf8)) || data.starts(with: Data("GIF89a".utf8))
    }

    private static func hasWebP(_ data: Data) -> Bool {
        data.count >= 12 &&
            data.prefix(4) == Data("RIFF".utf8) &&
            data.subdata(in: 8 ..< 12) == Data("WEBP".utf8)
    }

    private static func hasHEIC(_ data: Data) -> Bool {
        guard data.count >= 12, ascii(data, 4, 4) == "ftyp" else { return false }
        let brands = ftypBrands(data)
        let heic: Set = ["heic", "heix", "hevc", "hevx", "heim", "heis", "hevm", "hevs", "mif1"]
        guard let major = brands.first, major != "avif", major != "avis" else { return false }
        return brands.contains(where: heic.contains)
    }

    private static func ftypBrands(_ data: Data) -> [String] {
        let boxLength = min(data.count, Int(readUInt32(data.prefix(4))))
        guard boxLength >= 12 else { return [] }
        var brands = [ascii(data, 8, 4)]
        var offset = 16
        while offset + 4 <= boxLength {
            brands.append(ascii(data, offset, 4))
            offset += 4
        }
        return brands.filter { !$0.isEmpty }
    }

    private static func isSVG(_ data: Data) -> Bool {
        guard let prefix = String(data: data.prefix(512), encoding: .utf8)?.lowercased() else { return false }
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("<svg") || (trimmed.hasPrefix("<?xml") && prefix.contains("<svg"))
    }

    private static func isExecutable(_ data: Data) -> Bool {
        if data.starts(with: [0x4D, 0x5A]) || data.starts(with: [0x7F, 0x45, 0x4C, 0x46]) {
            return true
        }
        if data.starts(with: [0xFE, 0xED, 0xFA, 0xCE]) || data.starts(with: [0xFE, 0xED, 0xFA, 0xCF]) {
            return true
        }
        if data.starts(with: [0xCE, 0xFA, 0xED, 0xFE]) || data.starts(with: [0xCF, 0xFA, 0xED, 0xFE]) {
            return true
        }
        return data.starts(with: [0x23, 0x21])
    }

    private static func ascii(_ data: Data, _ offset: Int, _ count: Int) -> String {
        guard offset >= 0, count > 0, offset + count <= data.count else { return "" }
        return String(data: data.subdata(in: offset ..< (offset + count)), encoding: .ascii) ?? ""
    }

    private static func readUInt32(_ prefix: Data.SubSequence) -> UInt32 {
        prefix.prefix(4).reduce(UInt32(0)) { value, byte in (value << 8) | UInt32(byte) }
    }
}

enum IOSImageFilename {
    static func leaf(_ preferred: String) -> String {
        let normalized = preferred.replacingOccurrences(of: "\\", with: "/")
        let leaf = normalized.split(separator: "/").last.map(String.init) ?? ""
        if leaf.isEmpty || leaf == "." || leaf == ".." {
            return "image"
        }
        return leaf
    }

    static func rasterKind(of leaf: String) -> IOSImageRasterKind? {
        switch pathExtension(leaf) {
        case "png": .png
        case "jpg", "jpeg": .jpeg
        case "gif": .gif
        case "webp": .webp
        default: nil
        }
    }

    static func extensionMatches(_ leaf: String, kind: IOSImageRasterKind) -> Bool {
        let ext = pathExtension(leaf)
        if ext.isEmpty {
            return true
        }
        switch kind {
        case .png: return ext == "png"
        case .jpeg: return ext == "jpg" || ext == "jpeg"
        case .gif: return ext == "gif"
        case .webp: return ext == "webp"
        }
    }

    static func isHEICLeaf(_ leaf: String) -> Bool {
        let ext = pathExtension(leaf)
        return ext.isEmpty || ext == "heic" || ext == "heif"
    }

    static func ensuringExtension(_ leaf: String, kind: IOSImageRasterKind) -> String {
        if rasterKind(of: leaf) == kind {
            return leaf
        }
        return replacingExtension(leaf, with: kind.canonicalExtension)
    }

    private static func pathExtension(_ leaf: String) -> String {
        (leaf as NSString).pathExtension.lowercased()
    }

    static func replacingExtension(_ leaf: String, with pathExtension: String) -> String {
        let stem = (leaf as NSString).deletingPathExtension
        let base = stem.isEmpty || stem == "." ? "image" : stem
        return "\(base).\(pathExtension)"
    }
}
