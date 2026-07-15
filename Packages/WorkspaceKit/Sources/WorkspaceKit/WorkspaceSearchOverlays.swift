import Foundation

public enum WorkspaceSearchOverlayPathError: Sendable, Equatable {
    case emptyPath
    case absolutePath
    case pathTraversal
}

public enum WorkspaceSearchOverlayValidationError: Error, Sendable, Equatable {
    case invalidPath(path: String, reason: WorkspaceSearchOverlayPathError)
    case keyPathMismatch(key: String, overlayRelativePath: String)
    case normalizedCollision(relativePath: String)
}

/// Immutable unsaved text that takes precedence over on-disk workspace content.
public struct WorkspaceSearchOverlay: Sendable, Equatable {
    public let relativePath: String
    public let text: String

    public init(relativePath: String, text: String) throws {
        self.relativePath = try WorkspaceSearchOverlayCollection.normalizedPath(relativePath)
        self.text = text
    }
}

/// Validated, normalized dirty overlays for one search request.
///
/// Invalid paths, key/path mismatches, and multiple inputs that normalize to the same path
/// bytes are rejected. Canonically equivalent Unicode spellings remain distinct filesystem
/// paths. No winner is selected according to dictionary iteration order.
public struct WorkspaceSearchOverlayCollection: Sendable, Equatable {
    public static let empty = WorkspaceSearchOverlayCollection(storage: [:])

    private let storage: [WorkspacePathByteKey: WorkspaceSearchOverlay]

    public init(_ overlays: [WorkspaceSearchOverlay]) throws {
        var storage: [WorkspacePathByteKey: WorkspaceSearchOverlay] = [:]
        for overlay in overlays.sorted(by: {
            WorkspacePathByteKey($0.relativePath) < WorkspacePathByteKey($1.relativePath)
        }) {
            let pathKey = WorkspacePathByteKey(overlay.relativePath)
            guard storage.updateValue(overlay, forKey: pathKey) == nil else {
                throw WorkspaceSearchOverlayValidationError.normalizedCollision(
                    relativePath: overlay.relativePath
                )
            }
        }
        self.storage = storage
    }

    /// Validates legacy/keyed inputs without trusting either the dictionary key or value path.
    public init(validating overlays: [String: WorkspaceSearchOverlay]) throws {
        var storage: [WorkspacePathByteKey: WorkspaceSearchOverlay] = [:]
        for key in overlays.keys.sorted(by: {
            WorkspacePathByteKey($0) < WorkspacePathByteKey($1)
        }) {
            guard let overlay = overlays[key] else { continue }
            let normalizedKey = try Self.normalizedPath(key)
            let pathKey = WorkspacePathByteKey(normalizedKey)
            guard pathKey == WorkspacePathByteKey(overlay.relativePath) else {
                throw WorkspaceSearchOverlayValidationError.keyPathMismatch(
                    key: key,
                    overlayRelativePath: overlay.relativePath
                )
            }
            guard storage.updateValue(overlay, forKey: pathKey) == nil else {
                throw WorkspaceSearchOverlayValidationError.normalizedCollision(
                    relativePath: normalizedKey
                )
            }
        }
        self.storage = storage
    }

    public var overlays: [WorkspaceSearchOverlay] {
        storage.sorted { $0.key < $1.key }.map(\.value)
    }

    subscript(relativePath: String) -> WorkspaceSearchOverlay? {
        storage[WorkspacePathByteKey(relativePath)]
    }

    fileprivate init(storage: [WorkspacePathByteKey: WorkspaceSearchOverlay]) {
        self.storage = storage
    }

    static func normalizedPath(_ path: String) throws -> String {
        do {
            return try WorkspaceRootContainment.normalizedRelativePath(path)
        } catch WorkspaceRootContainmentError.emptyRelativePath {
            throw WorkspaceSearchOverlayValidationError.invalidPath(
                path: path,
                reason: .emptyPath
            )
        } catch WorkspaceRootContainmentError.absolutePath {
            throw WorkspaceSearchOverlayValidationError.invalidPath(
                path: path,
                reason: .absolutePath
            )
        } catch WorkspaceRootContainmentError.traversal {
            throw WorkspaceSearchOverlayValidationError.invalidPath(
                path: path,
                reason: .pathTraversal
            )
        } catch {
            throw WorkspaceSearchOverlayValidationError.invalidPath(
                path: path,
                reason: .pathTraversal
            )
        }
    }
}
