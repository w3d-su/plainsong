import Foundation

/// iOS bookmark and security-scope ports.
///
/// The iOS 27 SDK marks `NSURLBookmarkCreationWithSecurityScope` and
/// `NSURLBookmarkResolutionWithSecurityScope` as unavailable on iOS. Bookmarks
/// are created without that macOS flag. Resolution uses `withoutImplicitStartAccessing`
/// so this service, not an implicit start, pairs `startAccessingSecurityScopedResource`.
struct IOSSystemSecurityScopePort: IOSSecurityScopePort {
    func begin(url: URL, provenance: IOSAccessProvenance) -> IOSScopeAdmission {
        if url.startAccessingSecurityScopedResource() {
            return .started
        }
        switch provenance {
        case .appContainer:
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                return .reachableWithoutNewScope
            }
            return .denied
        case .userSelection, .bookmarkRestore:
            // A false start is not access. Reachability of this exact URL, never its parent,
            // covers picker callbacks and app-container files. Anything else stays denied.
            if FileManager.default.isReadableFile(atPath: url.path(percentEncoded: false)) {
                return .reachableWithoutNewScope
            }
            return .denied
        }
    }

    func end(url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}

struct IOSSystemBookmarkPort: IOSBookmarkPort {
    func bookmark(for url: URL) throws -> Data {
        do {
            return try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            throw IOSWorkspaceFailureMapping.map(error)
        }
    }

    func resolve(_ bookmark: Data) throws -> IOSBookmarkResolution {
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withoutUI, .withoutMounting, .withoutImplicitStartAccessing],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return .resolved(url, isStale: isStale)
        } catch {
            let failure = IOSWorkspaceFailureMapping.map(error)
            return IOSBookmarkResolution(url: nil, isStale: false, failure: failure)
        }
    }
}

/// File-system identifiers available on iOS are inode, volume, or kernel document ids.
/// None of those is a File Provider item identifier, so production reads stay unknown.
struct IOSSystemProviderIdentityPort: IOSProviderIdentityPort {
    func identity(for url: URL, relativePath: String) -> Data? {
        _ = url
        _ = relativePath
        return nil
    }
}

final class IOSUserDefaultsRecentStore: IOSRecentWorkspaceStoring, @unchecked Sendable {
    static let defaultKey = "Plainsong.IOSRecentWorkspaceGrants"

    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    init(defaults: UserDefaults, key: String = IOSUserDefaultsRecentStore.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    func load() -> [IOSStoredRecentWorkspace] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([IOSStoredRecentWorkspace].self, from: data)) ?? []
    }

    func save(_ items: [IOSStoredRecentWorkspace]) {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: key)
    }
}

enum IOSSystemAccessPorts {
    static func make(
        recents: UserDefaults = .standard,
        recentKey: String = IOSUserDefaultsRecentStore.defaultKey,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) -> IOSWorkspaceAccessPorts {
        IOSWorkspaceAccessPorts(
            scope: IOSSystemSecurityScopePort(),
            bookmarks: IOSSystemBookmarkPort(),
            identity: IOSSystemProviderIdentityPort(),
            files: IOSSystemWorkspaceFilePort(),
            recents: IOSUserDefaultsRecentStore(defaults: recents, key: recentKey),
            watcher: IOSSystemWorkspaceWatcher(),
            clock: clock,
            coordinationTimeoutNanoseconds: IOSWorkspaceAccessPorts.defaultTimeoutNanoseconds
        )
    }
}
