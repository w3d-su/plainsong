import Foundation
import WorkspaceCore
@testable import WorkspaceKitIOS

final class ScriptedScopePort: IOSSecurityScopePort, @unchecked Sendable {
    private let lock = NSLock()
    private var began: [URL] = []
    private var ended: [URL] = []
    var admission: IOSScopeAdmission = .started

    func begin(url: URL, provenance: IOSAccessProvenance) -> IOSScopeAdmission {
        lock.lock()
        defer { lock.unlock() }
        began.append(url)
        _ = provenance
        return admission
    }

    func end(url: URL) {
        lock.lock()
        defer { lock.unlock() }
        ended.append(url)
    }

    var beganURLs: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return began
    }

    var endCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return ended.count
    }
}

final class ScriptedBookmarkPort: IOSBookmarkPort, @unchecked Sendable {
    private let lock = NSLock()
    var resolution = IOSBookmarkResolution(url: nil, isStale: false, failure: nil)
    var refreshed = Data("refreshed-bookmark".utf8)
    var onBookmark: (@Sendable () throws -> Void)?
    private(set) var bookmarkCalls = 0

    func bookmark(for url: URL) throws -> Data {
        try onBookmark?()
        lock.lock()
        defer { lock.unlock() }
        bookmarkCalls += 1
        _ = url
        return refreshed
    }

    func resolve(_ bookmark: Data) throws -> IOSBookmarkResolution {
        _ = bookmark
        return resolution
    }

    var bookmarkCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return bookmarkCalls
    }
}

final class ScriptedIdentityPort: IOSProviderIdentityPort, @unchecked Sendable {
    var identity: Data?

    func identity(for url: URL, relativePath: String) -> Data? {
        _ = (url, relativePath)
        return identity
    }
}

final class ScriptedRecentStore: IOSRecentWorkspaceStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [IOSStoredRecentWorkspace] = []

    func load() -> [IOSStoredRecentWorkspace] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    func save(_ items: [IOSStoredRecentWorkspace]) {
        lock.lock()
        defer { lock.unlock() }
        self.items = items
    }
}
