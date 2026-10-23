import Foundation

enum AssetReadBegin: Sendable {
    case ready(AssetReadCapture)
    case missingURL
    case staleToken
    case missingAuthority
    case invalidated
}

final class AssetURLSchemeHandlerState: @unchecked Sendable {
    private let lock = NSLock()
    private var allowedRoot: URL?
    private var plainsongRootToken = UUID().uuidString
    private var access: PreviewAssetAccessContext?
    private var providerGrantInstalled = false
    private var reportedMissingDirectoryGrant = false
    private var macGeneration: UInt64 = 0
    private var invalidated = false
    private var stoppedTaskIDs: Set<ObjectIdentifier> = []
    private var reads: [ObjectIdentifier: Task<Void, Never>] = [:]

    func updateAllowedRoot(_ root: URL?) -> String {
        lock.lock()
        defer { lock.unlock() }
        let previousSpelling = allowedRoot?.absoluteString ?? ""
        let nextSpelling = root?.absoluteString ?? ""
        if !previousSpelling.utf8.elementsEqual(nextSpelling.utf8) || providerGrantInstalled {
            plainsongRootToken = UUID().uuidString
            if let root {
                macGeneration += 1
                access = PreviewAssetAccessContext(
                    allowedRoot: root,
                    rootToken: UUID(),
                    grantIdentity: Self.macDirectGrantIdentity,
                    accessGeneration: macGeneration
                )
            } else {
                access = nil
            }
            providerGrantInstalled = false
        }
        allowedRoot = root
        return plainsongRootToken
    }

    func updateAuthority(_ context: PreviewAssetAccessContext?) -> AssetAuthorityInstallation {
        lock.lock()
        defer { lock.unlock() }
        if !AssetAuthority.matches(access, context) {
            plainsongRootToken = UUID().uuidString
        }
        access = context
        allowedRoot = context?.allowedRoot
        providerGrantInstalled = context != nil
        let reportsMissingDirectoryGrant: Bool
        if context == nil {
            reportsMissingDirectoryGrant = !reportedMissingDirectoryGrant
            reportedMissingDirectoryGrant = true
        } else {
            reportedMissingDirectoryGrant = false
            reportsMissingDirectoryGrant = false
        }
        return AssetAuthorityInstallation(
            token: plainsongRootToken,
            reportsMissingDirectoryGrant: reportsMissingDirectoryGrant
        )
    }

    func currentToken() -> String {
        lock.lock()
        defer { lock.unlock() }
        return plainsongRootToken
    }

    func matches(_ context: PreviewAssetAccessContext) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return AssetAuthority.matches(access, context)
    }

    func begin(url: URL?, taskID: ObjectIdentifier) -> AssetReadBegin {
        lock.lock()
        defer { lock.unlock() }
        stoppedTaskIDs.remove(taskID)
        if invalidated {
            return .invalidated
        }
        guard let url else { return .missingURL }
        guard let allowedRoot, let access else { return .missingAuthority }
        guard let requested = Self.plainsongToken(in: url), requested == plainsongRootToken else {
            return .staleToken
        }
        return .ready(AssetReadCapture(
            plainsongRootToken: plainsongRootToken,
            access: access,
            allowedRoot: allowedRoot,
            requestID: UUID()
        ))
    }

    func store(_ task: Task<Void, Never>, id: ObjectIdentifier) {
        lock.lock()
        let superseded = invalidated || stoppedTaskIDs.contains(id)
        if superseded {
            lock.unlock()
            task.cancel()
            return
        }
        reads[id] = task
        lock.unlock()
    }

    func stop(_ taskID: ObjectIdentifier) {
        lock.lock()
        stoppedTaskIDs.insert(taskID)
        let task = reads.removeValue(forKey: taskID)
        lock.unlock()
        task?.cancel()
    }

    func invalidate() {
        lock.lock()
        invalidated = true
        plainsongRootToken = UUID().uuidString
        access = nil
        allowedRoot = nil
        let pending = reads
        reads.removeAll()
        lock.unlock()
        pending.values.forEach { $0.cancel() }
    }

    func permission(for capture: AssetReadCapture, taskID: ObjectIdentifier) -> AssetReadCompletionPermission {
        lock.lock()
        defer { lock.unlock() }
        return AssetReadCompletionFence.permission(
            stopped: stoppedTaskIDs.contains(taskID),
            invalidated: invalidated,
            captured: capture,
            currentToken: plainsongRootToken,
            currentAccess: access,
            currentRoot: allowedRoot
        )
    }

    private static let macDirectGrantIdentity = UUID(uuidString: "C0FFEE00-0000-4000-8000-000000000007")!

    private static func plainsongToken(in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == "plainsong-root" }?
            .value
    }
}
