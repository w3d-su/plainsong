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

    public static func startAccessing(_ url: URL) -> SecurityScopedResourceAccess {
        SecurityScopedResourceAccess(url: url)
    }
}

public final class SecurityScopedResourceAccess: @unchecked Sendable {
    public let url: URL

    private let didStartAccessing: Bool
    private let lock = NSLock()
    private var isStopped = false

    fileprivate init(url: URL) {
        self.url = url
        didStartAccessing = url.startAccessingSecurityScopedResource()
    }

    deinit {
        stop()
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }

        guard didStartAccessing, !isStopped else { return }
        url.stopAccessingSecurityScopedResource()
        isStopped = true
    }
}
