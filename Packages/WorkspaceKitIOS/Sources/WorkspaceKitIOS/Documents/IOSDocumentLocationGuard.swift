import Foundation
import WorkspaceCore

/// Compares grant and location by exact UTF-8 spelling. It does not resolve symlinks,
/// standardize Unicode, or consult Darwin device identity.
enum IOSDocumentLocationGuard {
    static func authorize(location: IOSFileLocation, grant: IOSWorkspaceGrant) -> Bool {
        guard location.workspaceID == grant.workspaceID else { return false }
        guard location.accessGeneration == grant.accessGeneration else { return false }
        guard location.fileURL.isFileURL, grant.rootURL.isFileURL else { return false }
        guard isSafeRelativePath(location.relativePath) else { return false }
        guard recognizedDocumentExtension(location.relativePath) != nil else { return false }

        let root = Data(grant.rootURL.path(percentEncoded: false).utf8)
        let file = Data(location.fileURL.path(percentEncoded: false).utf8)
        switch grant.scope {
        case .singleFile:
            return root == file
        case .directory:
            var expected = grant.rootURL.path(percentEncoded: false)
            if !expected.hasSuffix("/") {
                expected.append("/")
            }
            expected.append(location.relativePath)
            return Data(expected.utf8) == file
        }
    }

    static func isSafeRelativePath(_ relativePath: String) -> Bool {
        let bytes = Array(relativePath.utf8)
        if bytes.isEmpty || bytes.contains(0) || bytes.first == UInt8(ascii: "/") {
            return false
        }
        var component = [UInt8]()
        func rejectCurrent() -> Bool {
            component == [UInt8(ascii: ".")] || component == [UInt8(ascii: "."), UInt8(ascii: ".")]
        }
        for byte in bytes {
            if byte == UInt8(ascii: "/") {
                if component.isEmpty || rejectCurrent() {
                    return false
                }
                component.removeAll(keepingCapacity: true)
            } else {
                component.append(byte)
            }
        }
        return !component.isEmpty && !rejectCurrent()
    }

    static func recognizedDocumentExtension(_ relativePath: String) -> String? {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard let name = parts.last, !name.isEmpty else { return nil }
        let nameString = String(name)
        guard let dot = nameString.lastIndex(of: ".") else { return nil }
        let extStart = nameString.index(after: dot)
        guard extStart < nameString.endIndex else { return nil }
        let value = nameString[extStart...].lowercased()
        switch value {
        case "md", "markdown", "mdx":
            return value
        default:
            return nil
        }
    }
}
