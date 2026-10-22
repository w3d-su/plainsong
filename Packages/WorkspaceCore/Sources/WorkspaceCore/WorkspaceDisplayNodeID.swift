import Foundation

/// Display identity for a tree row. This is not file-operation authority.
public enum WorkspaceDisplayNodeID {
    public static func make(identity: String?, relativePath: String) -> String {
        guard let identity else {
            return fallbackPrefix + WorkspacePathByteKey(relativePath).asciiHex
        }
        return identity
    }

    static func disambiguated(_ nodeID: String, relativePath: String) -> String {
        duplicatePrefix
            + WorkspacePathByteKey(nodeID).asciiHex
            + ":"
            + WorkspacePathByteKey(relativePath).asciiHex
    }

    static let root = "__workspace_root__"

    private static let fallbackPrefix = "__workspace_path_bytes__:"
    private static let duplicatePrefix = "__workspace_duplicate_identity__:"
}
