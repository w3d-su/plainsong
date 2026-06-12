import Foundation

public enum SecurityScopedAccess {
    public static func withAccess<T>(to url: URL, _ body: () throws -> T) rethrows -> T {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try body()
    }
}
