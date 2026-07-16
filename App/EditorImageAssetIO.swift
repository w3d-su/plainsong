import CryptoKit
import Darwin
import EditorKit
import Foundation
import MarkdownCore
import WorkspaceKit

struct EditorImageAssetStableMetadata: Equatable {
    let identity: WorkspaceFileSystemIdentity
    let byteCount: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let changeSeconds: Int64
    let changeNanoseconds: Int64
}

struct EditorImageAssetNamespaceEntrySnapshot: Equatable {
    let identity: WorkspaceFileSystemIdentity
    let fileType: mode_t
}

enum EditorImageAssetNamespaceEntryInspection {
    case present(EditorImageAssetNamespaceEntrySnapshot)
    case missing
    case indeterminate(String)
}

enum EditorImageAssetDescriptorLinkInspection {
    case linked
    case unlinked
    case indeterminate(String)
}

func inspectEditorImageAssetNamespaceEntry(
    directoryDescriptor: Int32,
    leafName: String
) -> EditorImageAssetNamespaceEntryInspection {
    var status = stat()
    let result = leafName.withCString {
        Darwin.fstatat(directoryDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
    }
    guard result == 0 else {
        let failure = errno
        return failure == ENOENT
            ? .missing
            : .indeterminate(editorImageErrorDescription(failure))
    }
    return .present(editorImageAssetNamespaceEntrySnapshot(status: status))
}

func editorImageAssetNamespaceEntrySnapshot(
    descriptor: Int32
) -> EditorImageAssetNamespaceEntrySnapshot? {
    var status = stat()
    guard Darwin.fstat(descriptor, &status) == 0 else { return nil }
    return editorImageAssetNamespaceEntrySnapshot(status: status)
}

func inspectEditorImageAssetDescriptorLinks(
    descriptor: Int32
) -> EditorImageAssetDescriptorLinkInspection {
    var status = stat()
    guard Darwin.fstat(descriptor, &status) == 0 else {
        return .indeterminate(editorImageErrorDescription(errno))
    }
    return status.st_nlink == 0 ? .unlinked : .linked
}

private func editorImageAssetNamespaceEntrySnapshot(
    status: stat
) -> EditorImageAssetNamespaceEntrySnapshot {
    EditorImageAssetNamespaceEntrySnapshot(
        identity: WorkspaceFileSystemIdentity(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino)
        ),
        fileType: status.st_mode & S_IFMT
    )
}

func editorImageAssetContentProof(descriptor: Int32) throws -> EditorImageAssetContentProof {
    let before = try editorImageAssetStableMetadata(descriptor: descriptor)
    let digest = try editorImageSHA256Digest(descriptor: descriptor)
    let after = try editorImageAssetStableMetadata(descriptor: descriptor)
    guard before == after else { throw CocoaError(.fileReadUnknown) }
    return EditorImageAssetContentProof(
        identity: after.identity,
        byteCount: after.byteCount,
        sha256Digest: digest
    )
}

func editorImageAssetStableMetadata(
    descriptor: Int32
) throws -> EditorImageAssetStableMetadata {
    var status = stat()
    guard Darwin.fstat(descriptor, &status) == 0,
          (status.st_mode & S_IFMT) == S_IFREG
    else {
        throw editorImagePOSIXError()
    }
    return EditorImageAssetStableMetadata(
        identity: WorkspaceFileSystemIdentity(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino)
        ),
        byteCount: Int64(status.st_size),
        modificationSeconds: Int64(status.st_mtimespec.tv_sec),
        modificationNanoseconds: Int64(status.st_mtimespec.tv_nsec),
        changeSeconds: Int64(status.st_ctimespec.tv_sec),
        changeNanoseconds: Int64(status.st_ctimespec.tv_nsec)
    )
}

func validateEditorImageNamespaceEntry(
    directoryDescriptor: Int32,
    leafName: String,
    expectedIdentity: WorkspaceFileSystemIdentity
) throws {
    var status = stat()
    let result = leafName.withCString {
        Darwin.fstatat(directoryDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
    }
    guard result == 0,
          (status.st_mode & S_IFMT) == S_IFREG,
          WorkspaceFileSystemIdentity(
              device: UInt64(status.st_dev),
              inode: UInt64(status.st_ino)
          ) == expectedIdentity
    else {
        throw CocoaError(.fileReadUnknown)
    }
}

func editorImageSHA256Digest(descriptor: Int32) throws -> String {
    guard Darwin.lseek(descriptor, 0, SEEK_SET) >= 0 else { throw editorImagePOSIXError() }
    var hasher = SHA256()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let count = buffer.withUnsafeMutableBytes { bytes in
            Darwin.read(descriptor, bytes.baseAddress, bytes.count)
        }
        if count < 0, errno == EINTR { continue }
        guard count >= 0 else { throw editorImagePOSIXError() }
        guard count > 0 else { break }
        hasher.update(data: Data(buffer.prefix(count)))
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

func writeEditorImageData(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.write(
                descriptor,
                bytes.baseAddress?.advanced(by: offset),
                bytes.count - offset
            )
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw editorImagePOSIXError() }
            offset += count
        }
    }
}

func readEditorImageFile(from descriptor: Int32) throws -> Data {
    let before = try editorImageAssetStableMetadata(descriptor: descriptor)
    guard Darwin.lseek(descriptor, 0, SEEK_SET) >= 0 else { throw editorImagePOSIXError() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let count = buffer.withUnsafeMutableBytes { bytes in
            Darwin.read(descriptor, bytes.baseAddress, bytes.count)
        }
        if count < 0, errno == EINTR { continue }
        guard count >= 0 else { throw editorImagePOSIXError() }
        guard count > 0 else { break }
        guard Int64(data.count) + Int64(count) <= MarkdownImageAssetPolicy.maximumFileSizeBytes else {
            throw WorkspaceImageAssetStoreError.importedImageTooLarge(
                "image",
                maximumBytes: MarkdownImageAssetPolicy.maximumFileSizeBytes
            )
        }
        data.append(contentsOf: buffer.prefix(count))
    }
    let after = try editorImageAssetStableMetadata(descriptor: descriptor)
    guard before == after,
          after.byteCount == Int64(data.count)
    else {
        throw CocoaError(.fileReadUnknown)
    }
    return data
}

func withValidatedEditorImageFile<Result>(
    at fileURL: URL,
    _ body: (Int32) throws -> Result
) throws -> Result {
    guard fileURL.isFileURL,
          !fileURL.path(percentEncoded: false).utf8.contains(0)
    else {
        throw WorkspaceImageAssetStoreError.unsupportedImageType(fileURL.lastPathComponent)
    }
    try validateEditorImageFilename(fileURL.lastPathComponent)
    let descriptor = Darwin.open(
        fileURL.path(percentEncoded: false),
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY | O_NONBLOCK
    )
    guard descriptor >= 0 else { throw editorImagePOSIXError() }
    defer { Darwin.close(descriptor) }
    let metadata = try editorImageAssetStableMetadata(descriptor: descriptor)
    guard metadata.byteCount <= MarkdownImageAssetPolicy.maximumFileSizeBytes else {
        throw WorkspaceImageAssetStoreError.importedImageTooLarge(
            fileURL.lastPathComponent,
            maximumBytes: MarkdownImageAssetPolicy.maximumFileSizeBytes
        )
    }
    let resourceValues = try fileURL.resourceValues(forKeys: [.contentTypeKey])
    if let contentType = resourceValues.contentType,
       !allowedEditorImageTypes.contains(where: { contentType.conforms(to: $0) })
    {
        throw WorkspaceImageAssetStoreError.unsupportedImageType(fileURL.lastPathComponent)
    }
    return try body(descriptor)
}
