import AppKit
import Darwin
import Foundation
@testable import WorkspaceKit

/// Receives one Markdown file through LaunchServices (the same file-only App Sandbox extension
/// a Finder "Open With" or Open-panel grant carries), proves the grant really refuses a new
/// entry in the parent, then saves twice through the production `MarkdownFileStore`.
final class ProbeDelegate: NSObject, NSApplicationDelegate {
    private var handled = false

    func applicationDidFinishLaunching(_: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [self] in
            guard !handled else { return }
            finish(false, "no document was delivered by LaunchServices")
        }
    }

    func application(_: NSApplication, open urls: [URL]) {
        guard !handled, let url = urls.first else { return }
        handled = true
        do {
            try run(url)
            finish(true, "file-only grant: sibling create refused, two durable saves committed")
        } catch {
            finish(false, "\(error)")
        }
    }

    private func run(_ url: URL) throws {
        print("APP_SANDBOX_CONTAINER_ID=\(ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] ?? "nil")")
        print("document=\(url.path(percentEncoded: false))")
        try requireFileOnlyGrant(for: url)

        let store = MarkdownFileStore()
        let location = try WorkspaceFileSystemLocation(fileURL: url)
        var loaded = try store.loadResult(at: location)
        guard loaded.file.text == "# Original\n" else {
            throw ProbeFailure("unexpected fixture text \(loaded.file.text.debugDescription)")
        }
        for revision in 1 ... 2 {
            let text = "# Saved \(revision)\n"
            let outcome = try store.save(
                text: text,
                at: location,
                expecting: .existingContent(loaded.metadata.identity, sha256Digest: loaded.sha256Digest)
            )
            print("save\(revision)=\(outcome)")
            guard case let .committedAndDurable(result) = outcome, result.cleanupState == .none else {
                throw ProbeFailure("save \(revision) was not durable and clean: \(outcome)")
            }
            loaded = try store.loadResult(at: location)
            guard loaded.file.text == text, loaded.metadata.identity == result.metadata.identity else {
                throw ProbeFailure("save \(revision) did not publish its bytes")
            }
        }
    }

    /// Without this the probe could pass on a directory grant and prove nothing.
    private func requireFileOnlyGrant(for url: URL) throws {
        let parent = url.deletingLastPathComponent().path(percentEncoded: false)
        let parentDescriptor = parent.withCString { Darwin.open($0, O_SEARCH | O_DIRECTORY | O_CLOEXEC) }
        guard parentDescriptor >= 0 else {
            throw ProbeFailure("parent search open failed: errno \(errno)")
        }
        defer { Darwin.close(parentDescriptor) }
        let sibling = ".plainsong-probe-\(UUID().uuidString)"
        let created = sibling.withCString {
            Darwin.openat(parentDescriptor, $0, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        }
        let createError = errno
        if created >= 0 {
            Darwin.close(created)
            _ = sibling.withCString { Darwin.unlinkat(parentDescriptor, $0, 0) }
            throw ProbeFailure("the grant allowed a sibling create; the probe would be vacuous")
        }
        print("siblingCreateErrno=\(createError)")
        guard createError == EPERM else {
            throw ProbeFailure("sibling create failed with errno \(createError), expected EPERM")
        }
    }

    private func finish(_ passed: Bool, _ message: String) {
        print("\(passed ? "PASS" : "FAIL"): \(message)")
        fflush(stdout)
        exit(passed ? 0 : 1)
    }
}

struct ProbeFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

@main enum SingleFileSaveSandboxProbe {
    static func main() {
        let application = NSApplication.shared
        let delegate = ProbeDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.prohibited)
        application.run()
    }
}
