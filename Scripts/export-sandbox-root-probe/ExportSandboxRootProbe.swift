import Darwin
import Foundation
@testable import WorkspaceKit

final class AppState {}

@main struct ExportRootProbe {
    static func main() throws {
        let root = AppState.exportAppPrivateRoot()
        print("APP_SANDBOX_CONTAINER_ID=\(ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] ?? "nil")")
        print("NSHomeDirectory=\(NSHomeDirectory())")
        print("root=\(root?.path(percentEncoded: false) ?? "nil")")
        let deniedPath = "/private/tmp/plainsong-export-root-probe-denied-\(UUID().uuidString)"
        let denied = FileManager.default.createFile(atPath: deniedPath, contents: Data())
        print("outsideContainerWrite=\(denied)")
        guard let root, !denied, !FileManager.default.fileExists(atPath: deniedPath),
              root.path(percentEncoded: false) == NSHomeDirectory() + "/",
              ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == "app.plainsong.export-root-probe"
        else { exit(1) }
        let actualHome = String(cString: getpwuid(getuid()).pointee.pw_dir)
        let destination = URL(fileURLWithPath: actualHome)
            .appendingPathComponent("plainsong-probe-\(UUID().uuidString).html")
        print("destination=\(destination.path(percentEncoded: false))")
        let calls = ProbeCalls()
        let outcome = ExportArtifactWriter.write(
            ExportArtifactWriteRequest(destinationURL: destination, kind: .html, disposition: .createNew,
                                       bytes: Data("sandbox probe".utf8)),
            appPrivateRoot: root, ownership: { _ in .permitted },
            hooks: ExportArtifactWriterHooks(observer: { calls.append($0) })
        )
        print("writerOutcome=\(outcome)")
        print("privateRootCanonicalCalls=\(calls.values.filter { $0.step == .canonicalizePrivateRoot }.count)")
        print("stagedCreateCalls=\(calls.values.filter { $0.step == .createStaged }.count)")
        print("publishCalls=\(calls.values.filter { $0.step == .publish }.count)")
        guard calls.values.contains(where: { $0.step == .canonicalizePrivateRoot }),
              calls.values.contains(where: { $0.step == .createStaged }),
              outcome == .notCommitted(.publicationNotPermitted(code: EPERM)),
              !FileManager.default.fileExists(atPath: destination.path(percentEncoded: false))
        else { exit(1) }
        for call in calls.values where call.step == .createStaged {
            guard !FileManager.default.fileExists(atPath: call.path),
                  !FileManager.default.fileExists(atPath: (call.path as NSString).deletingLastPathComponent)
            else { exit(1) }
        }
        let nilRootCalls = ProbeCalls()
        let nilRootOutcome = ExportArtifactWriter.write(
            ExportArtifactWriteRequest(destinationURL: destination, kind: .html, disposition: .createNew,
                                       bytes: Data("sandbox probe".utf8)),
            appPrivateRoot: nil, ownership: { _ in .permitted },
            hooks: ExportArtifactWriterHooks(observer: { nilRootCalls.append($0) })
        )
        print("nilRootControl=\(nilRootOutcome)")
        guard nilRootOutcome == .notCommitted(.stagingDirectoryInsideDestinationFolder),
              !nilRootCalls.values.contains(where: { $0.step == .createStaged || $0.step == .publish }),
              nilRootCalls.values.contains(where: { $0.step == .removeStagingDirectory }) else { exit(1) }
        for call in nilRootCalls.values where call.step == .removeStagingDirectory {
            guard !FileManager.default.fileExists(atPath: call.path) else { exit(1) }
        }
        print(
            "PASS: default root admits rule (b), nil root refuses, unauthorized publication and outside writes are denied, operation paths are absent"
        )
    }
}

final class ProbeCalls: @unchecked Sendable {
    let lock = NSLock()
    private var calls: [ExportArtifactWriterCall] = []
    var values: [ExportArtifactWriterCall] {
        lock.lock(); defer { lock.unlock() }; return calls
    }

    func append(_ call: ExportArtifactWriterCall) {
        lock.lock(); defer { lock.unlock() }; calls.append(call)
    }
}
