import Darwin
import Foundation

struct ExportArtifactVolumeCapabilities: Equatable {
    let exclusiveRename: Bool
    let exchangeRename: Bool
}

/// Test seams. Production uses the audited filesystem hooks unchanged and probes the real
/// volume; tests inject syscall-boundary failures, races, and unsupported volume semantics.
struct ExportArtifactWriterHooks {
    static let production = ExportArtifactWriterHooks()

    let fileSystem: WorkspaceAnchoredFileSystem.Hooks
    let volumeCapabilities: (@Sendable (Int32) -> ExportArtifactVolumeCapabilities)?
    let afterPreflight: (@Sendable () -> Void)?
    let afterPublication: (@Sendable () -> Void)?

    init(
        fileSystem: WorkspaceAnchoredFileSystem.Hooks = .production,
        volumeCapabilities: (@Sendable (Int32) -> ExportArtifactVolumeCapabilities)? = nil,
        afterPreflight: (@Sendable () -> Void)? = nil,
        afterPublication: (@Sendable () -> Void)? = nil
    ) {
        self.fileSystem = fileSystem
        self.volumeCapabilities = volumeCapabilities
        self.afterPreflight = afterPreflight
        self.afterPublication = afterPublication
    }
}

/// The literal panel URL split without Foundation path normalization.
struct ExportArtifactSelection {
    let destinationURL: URL
    let parentPath: String
    let leaf: String

    static func parse(
        _ url: URL,
        kind: ExportArtifactKind
    ) -> Result<ExportArtifactSelection, ExportArtifactFailure> {
        guard url.isFileURL, !url.hasDirectoryPath,
              let path = try? WorkspaceLiteralFileURL.absolutePath(of: url)
        else {
            return .failure(.invalidDestinationURL)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let leaf = components.last,
              !components.contains(where: { $0 == "." || $0 == ".." })
        else {
            return .failure(.invalidDestinationURL)
        }
        guard hasAllowedExtension(String(leaf), kind: kind) else {
            return .failure(.unsupportedExtension)
        }
        let parentPath = "/" + components.dropLast().joined(separator: "/")
        return .success(ExportArtifactSelection(
            destinationURL: url,
            parentPath: parentPath,
            leaf: String(leaf)
        ))
    }

    /// Requires a non-empty base name and an ASCII extension from the kind's allowlist.
    static func hasAllowedExtension(_ leaf: String, kind: ExportArtifactKind) -> Bool {
        let bytes = Array(leaf.utf8)
        guard let dot = bytes.lastIndex(of: 0x2E), dot > 0, dot < bytes.count - 1 else {
            return false
        }
        var extensionBytes: [UInt8] = []
        for byte in bytes[(dot + 1)...] {
            switch byte {
            case 0x41 ... 0x5A: extensionBytes.append(byte + 0x20)
            case 0x61 ... 0x7A, 0x30 ... 0x39: extensionBytes.append(byte)
            default: return false
            }
        }
        return kind.allowedExtensions.contains { $0.utf8.elementsEqual(extensionBytes) }
    }
}

struct ExportArtifactPreflight {
    let location: WorkspaceFileSystemLocation
    let inspection: WorkspaceNoFollowFileTargetInspection
}

extension ExportArtifactWriter {
    /// Establishes the exact parent authority and inspects the selected leaf. Runs inside the
    /// caller's security scope for the exact panel URL; never starts access on the parent.
    static func preflight(
        _ selection: ExportArtifactSelection,
        hooks: ExportArtifactWriterHooks
    ) -> Result<ExportArtifactPreflight, ExportArtifactFailure> {
        let location: WorkspaceFileSystemLocation
        do {
            location = try WorkspaceFileSystemLocation(fileURL: selection.destinationURL)
            try validateParentPathHasNoSymbolicLink(selection, location: location)
        } catch let failure as ExportArtifactFailure {
            return .failure(failure)
        } catch {
            return .failure(parentAuthorityFailure(error))
        }

        let inspection: WorkspaceNoFollowFileTargetInspection
        do {
            inspection = try WorkspaceAnchoredFileSystem.inspectFileTarget(
                location,
                hooks: hooks.fileSystem
            )
        } catch {
            return .failure(destinationFailure(error))
        }
        guard inspection.canonicalLocation == location else {
            return .failure(.destinationAlias)
        }

        let capabilities = location.rootAuthority.withRetainedRootDescriptor { descriptor in
            hooks.volumeCapabilities?(descriptor) ?? probeVolumeCapabilities(descriptor)
        }
        let requiresExchange = inspection.state != .missing
        guard capabilities.exclusiveRename, !requiresExchange || capabilities.exchangeRename else {
            return .failure(.unsupportedVolumeSemantics)
        }
        return .success(ExportArtifactPreflight(location: location, inspection: inspection))
    }

    /// Root capture follows aliases once to find the physical parent. The export contract
    /// forbids following a symlink anywhere in the selected path, so the literal parent
    /// spelling must name that same directory with `O_NOFOLLOW_ANY`.
    private static func validateParentPathHasNoSymbolicLink(
        _ selection: ExportArtifactSelection,
        location: WorkspaceFileSystemLocation
    ) throws {
        let descriptor = selection.parentPath.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else {
            throw switch errno {
            case ELOOP: ExportArtifactFailure.symbolicLinkInParentPath
            case ENOENT, ENOTDIR: ExportArtifactFailure.namespaceChanged
            default: ExportArtifactFailure.parentAuthorityUnavailable
            }
        }
        defer { Darwin.close(descriptor) }
        guard let identity = try? WorkspaceAnchoredFileSystem.directoryDescriptorIdentity(descriptor),
              identity == location.rootAuthority.physicalIdentity
        else {
            throw ExportArtifactFailure.namespaceChanged
        }
    }

    private static func parentAuthorityFailure(_ error: Error) -> ExportArtifactFailure {
        switch error {
        case WorkspaceAnchoredFileSystemError.cancelled: .cancelled
        case WorkspaceAnchoredFileSystemError.namespaceChanged: .namespaceChanged
        case is WorkspaceAnchoredFileSystemError: .parentAuthorityUnavailable
        default: .invalidDestinationURL
        }
    }

    private static func destinationFailure(_ error: Error) -> ExportArtifactFailure {
        switch WorkspaceAnchoredFileSystem.normalizedError(error) {
        case .symbolicLink: .symbolicLinkDestination
        case .notRegularFile: .nonRegularDestination
        case .missing, .unreadable: .parentAuthorityUnavailable
        case .cancelled: .cancelled
        case .changedIdentity, .changedContent, .namespaceChanged, .unstable: .namespaceChanged
        case .durabilityFailed, .cleanupFailed: .parentAuthorityUnavailable
        }
    }

    /// Reads `VOL_CAP_INT_RENAME_EXCL` / `VOL_CAP_INT_RENAME_SWAP` from the anchored parent.
    /// A volume that does not report a capability as valid is treated as unsupported.
    static func probeVolumeCapabilities(_ descriptor: Int32) -> ExportArtifactVolumeCapabilities {
        struct Buffer {
            var length: UInt32 = 0
            var attributes = vol_capabilities_attr_t()
        }
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_CAPABILITIES)
        var buffer = Buffer()
        let result = withUnsafeMutableBytes(of: &buffer) { bytes in
            Darwin.fgetattrlist(descriptor, &request, bytes.baseAddress, bytes.count, 0)
        }
        guard result == 0,
              Int(buffer.length) >= MemoryLayout<UInt32>.size + MemoryLayout<vol_capabilities_attr_t>.size
        else {
            return ExportArtifactVolumeCapabilities(exclusiveRename: false, exchangeRename: false)
        }
        let valid = buffer.attributes.valid.1
        let interfaces = buffer.attributes.capabilities.1
        func supports(_ flag: some BinaryInteger) -> Bool {
            let bit = UInt32(flag)
            return valid & bit != 0 && interfaces & bit != 0
        }
        return ExportArtifactVolumeCapabilities(
            exclusiveRename: supports(VOL_CAP_INT_RENAME_EXCL),
            exchangeRename: supports(VOL_CAP_INT_RENAME_SWAP)
        )
    }
}
