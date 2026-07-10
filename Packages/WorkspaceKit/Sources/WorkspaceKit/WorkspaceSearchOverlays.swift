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

/// Validated, canonical dirty overlays for one search request.
///
/// Invalid paths, key/path mismatches, and multiple inputs that normalize to the same path
/// are rejected. No winner is selected according to dictionary iteration order.
public struct WorkspaceSearchOverlayCollection: Sendable, Equatable {
    public static let empty = WorkspaceSearchOverlayCollection(storage: [:])

    private let storage: [String: WorkspaceSearchOverlay]

    public init(_ overlays: [WorkspaceSearchOverlay]) throws {
        var storage: [String: WorkspaceSearchOverlay] = [:]
        for overlay in overlays.sorted(by: { $0.relativePath < $1.relativePath }) {
            guard storage.updateValue(overlay, forKey: overlay.relativePath) == nil else {
                throw WorkspaceSearchOverlayValidationError.normalizedCollision(
                    relativePath: overlay.relativePath
                )
            }
        }
        self.storage = storage
    }

    /// Validates legacy/keyed inputs without trusting either the dictionary key or value path.
    public init(validating overlays: [String: WorkspaceSearchOverlay]) throws {
        var storage: [String: WorkspaceSearchOverlay] = [:]
        for key in overlays.keys.sorted() {
            guard let overlay = overlays[key] else { continue }
            let normalizedKey = try Self.normalizedPath(key)
            guard normalizedKey == overlay.relativePath else {
                throw WorkspaceSearchOverlayValidationError.keyPathMismatch(
                    key: key,
                    overlayRelativePath: overlay.relativePath
                )
            }
            guard storage.updateValue(overlay, forKey: normalizedKey) == nil else {
                throw WorkspaceSearchOverlayValidationError.normalizedCollision(
                    relativePath: normalizedKey
                )
            }
        }
        self.storage = storage
    }

    public var overlays: [WorkspaceSearchOverlay] {
        storage.values.sorted { $0.relativePath < $1.relativePath }
    }

    subscript(relativePath: String) -> WorkspaceSearchOverlay? {
        storage[relativePath]
    }

    fileprivate init(storage: [String: WorkspaceSearchOverlay]) {
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
