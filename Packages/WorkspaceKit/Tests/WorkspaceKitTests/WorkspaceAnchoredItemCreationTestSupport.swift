import Foundation

final class DirectorySourceCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var capturedValue: URL?

    var value: URL? {
        lock.lock()
        defer { lock.unlock() }
        return capturedValue
    }

    func record(_ value: URL) {
        lock.lock()
        defer { lock.unlock() }
        capturedValue = value
    }
}

final class DirectorySourceReplacement: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: Error?
    private var sourceURL: URL?
    private var displacedURL: URL?
    private var sentinel: URL?

    var displacedSourceURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return displacedURL
    }

    var sentinelURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return sentinel
    }

    var originalSourceURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return sourceURL
    }

    func run(
        at sourceURL: URL,
        includeSentinel: Bool = true
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard self.sourceURL == nil else { return }

        let displacedURL = sourceURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".plainsong-held-source-\(UUID().uuidString)",
                isDirectory: true
            )
        let sentinel = sourceURL.appendingPathComponent("sentinel.txt")
        do {
            try FileManager.default.moveItem(
                at: sourceURL,
                to: displacedURL
            )
            try FileManager.default.createDirectory(
                at: sourceURL,
                withIntermediateDirectories: false
            )
            if includeSentinel {
                try "replacement".write(
                    to: sentinel,
                    atomically: false,
                    encoding: .utf8
                )
            }
            self.sourceURL = sourceURL
            self.displacedURL = displacedURL
            self.sentinel = includeSentinel ? sentinel : nil
        } catch {
            failure = error
        }
    }

    func rethrowIfFailed() throws {
        lock.lock()
        defer { lock.unlock() }
        if let failure {
            throw failure
        }
    }

    func cleanUp() {
        lock.lock()
        defer { lock.unlock() }
        if let sourceURL {
            try? FileManager.default.removeItem(at: sourceURL)
        }
        if let displacedURL {
            try? FileManager.default.removeItem(at: displacedURL)
        }
    }
}
