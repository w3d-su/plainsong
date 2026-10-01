import Foundation

extension AppState {
    /// The app-private staging root for one-shot export (owner decision 2026-09-30, E2 review):
    /// the sandbox container's data directory, which is `NSHomeDirectory()` only when the
    /// process runs sandboxed. It must end in `/Library/Containers/<APP_SANDBOX_CONTAINER_ID>/Data`.
    /// Unsandboxed, or for any other shape, it is `nil`, so staging inside the chosen folder is
    /// always refused. WorkspaceKit then proves the root exists, canonically, before staging.
    nonisolated static func exportAppPrivateRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory()
    ) -> URL? {
        guard let containerID = environment["APP_SANDBOX_CONTAINER_ID"], !containerID.isEmpty else {
            return nil
        }
        let components = homeDirectory.split(separator: "/", omittingEmptySubsequences: true)
        let expectedSuffix = ["Library", "Containers", containerID, "Data"]
        guard homeDirectory.hasPrefix("/"),
              components.count > expectedSuffix.count,
              zip(components.suffix(expectedSuffix.count), expectedSuffix)
              .allSatisfy({ $0.utf8.elementsEqual($1.utf8) })
        else {
            return nil
        }
        return URL(fileURLWithPath: homeDirectory, isDirectory: true)
    }
}
