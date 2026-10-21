import Foundation
import WorkspaceCore

/// Presents the granted root and forwards provider callbacks as notices.
/// Callbacks do not coordinate and do not touch the document session.
final class IOSSystemWorkspaceWatcher: IOSWorkspaceChangeWatching, @unchecked Sendable {
    private let lock = NSLock()
    private var presenters: [UUID: IOSRootFilePresenter] = [:]

    func start(
        root: URL,
        identity: IOSWorkspaceIdentity,
        sink: @escaping @Sendable (IOSExternalWorkspaceNotice) -> Void
    ) {
        let presenter = IOSRootFilePresenter(root: root, sink: sink)
        lock.lock()
        let previous = presenters.updateValue(presenter, forKey: identity.rawValue)
        lock.unlock()
        if let previous {
            NSFileCoordinator.removeFilePresenter(previous)
        }
        NSFileCoordinator.addFilePresenter(presenter)
    }

    func stop(identity: IOSWorkspaceIdentity) {
        lock.lock()
        let presenter = presenters.removeValue(forKey: identity.rawValue)
        lock.unlock()
        if let presenter {
            NSFileCoordinator.removeFilePresenter(presenter)
        }
    }
}

private final class IOSRootFilePresenter: NSObject, NSFilePresenter {
    let root: URL
    let sink: @Sendable (IOSExternalWorkspaceNotice) -> Void
    let operationQueue: OperationQueue

    init(root: URL, sink: @escaping @Sendable (IOSExternalWorkspaceNotice) -> Void) {
        self.root = root
        self.sink = sink
        let queue = OperationQueue()
        queue.name = "Plainsong.IOSWorkspaceChange"
        queue.maxConcurrentOperationCount = 1
        operationQueue = queue
    }

    var presentedItemURL: URL? {
        root
    }

    var presentedItemOperationQueue: OperationQueue {
        operationQueue
    }

    func presentedItemDidChange() {
        emit(.changed(relativePath: IOSWorkspacePathAuthority.lastComponent(root.path(percentEncoded: false))))
    }

    func accommodatePresentedItemDeletion(completionHandler: @escaping (Error?) -> Void) {
        presentedItemDidChange()
        emit(.deleted(relativePath: IOSWorkspacePathAuthority.lastComponent(root.path(percentEncoded: false))))
        completionHandler(nil)
    }

    func accommodatePresentedItemEviction(completionHandler: @escaping (Error?) -> Void) {
        emit(.offlineRoot)
        NSFileCoordinator.removeFilePresenter(self)
        completionHandler(nil)
    }

    func presentedItemDidMove(to newURL: URL) {
        let destination = IOSWorkspacePathAuthority.lastComponent(newURL.path(percentEncoded: false))
        emit(.moved(
            from: IOSWorkspacePathAuthority.lastComponent(root.path(percentEncoded: false)),
            to: destination
        ))
    }

    func presentedItemDidChangeUbiquityAttributes(_: Set<URLResourceKey>) {
        presentedItemDidChange()
    }

    func presentedSubitemDidAppear(at url: URL) {
        guard let relative = relativePath(for: url) else { return }
        emit(.changed(relativePath: relative))
    }

    func presentedSubitemDidChange(at url: URL) {
        guard let relative = relativePath(for: url) else { return }
        emit(.changed(relativePath: relative))
    }

    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) {
        guard let from = relativePath(for: oldURL) else { return }
        let destination = relativePath(for: newURL) ?? IOSWorkspacePathAuthority.lastComponent(
            newURL.path(percentEncoded: false)
        )
        emit(.moved(from: from, to: destination))
    }

    func accommodatePresentedSubitemDeletion(at url: URL, completionHandler: @escaping (Error?) -> Void) {
        if let relative = relativePath(for: url) {
            emit(.deleted(relativePath: relative))
        }
        completionHandler(nil)
    }

    private func emit(_ notice: IOSExternalWorkspaceNotice) {
        sink(notice)
    }

    private func relativePath(for url: URL) -> String? {
        let rootBytes = IOSWorkspacePathAuthority.pathBytes(root)
        let fileBytes = IOSWorkspacePathAuthority.pathBytes(url)
        guard fileBytes.count > rootBytes.count + 1 else { return nil }
        guard Array(fileBytes.prefix(rootBytes.count)) == rootBytes else { return nil }
        guard fileBytes[rootBytes.count] == UInt8(ascii: "/") else { return nil }
        let remainder = String(decoding: fileBytes.dropFirst(rootBytes.count + 1), as: UTF8.self)
        guard WorkspaceRelativePath(spelling: remainder) != nil else { return nil }
        return remainder
    }
}
