import Darwin
import Foundation

/// Foundation may create these shared ancestors at an external volume's root even when the
/// returned item-replacement directory is later refused. Metadata reads do not open or enumerate
/// the selected folder, and never authorize removal of a shared ancestor.
struct ExportArtifactFoundationScaffolding {
    let path: String
    enum Observation {
        case absent
        case identity(WorkspaceFileSystemIdentity)
        case unobservable
    }

    let before: Observation
}

extension ExportArtifactWriter {
    static func observeFoundationScaffolding(
        _ selection: ExportArtifactSelection,
        appPrivateRoot: URL?,
        hooks: ExportArtifactWriterHooks
    ) -> [ExportArtifactFoundationScaffolding] {
        let temporary = "\(selection.parentPath)/.TemporaryItems"
        var paths = [temporary, "\(temporary)/folders.\(getuid())"]
        if let appPrivateRoot, let rootPath = try? WorkspaceLiteralFileURL.absolutePath(of: appPrivateRoot),
           pathLiesStrictly(rootPath, inside: selection.parentPath)
        {
            let components = rootPath.split(separator: "/")
            let parentCount = selection.parentPath.split(separator: "/").count
            for count in (parentCount + 1) ... components.count {
                paths.append("/" + components.prefix(count).joined(separator: "/"))
            }
        }
        return paths.map { path in
            let before: ExportArtifactFoundationScaffolding.Observation = switch hooks.noFollowStatus(
                path,
                step: .inspectFoundationScaffolding
            ) {
            case let .success(status): .identity(WorkspaceFileSystemIdentity(exportStatus: status))
            case let .failure(failure) where failure.code == ENOENT: .absent
            case .failure: .unobservable
            }
            return ExportArtifactFoundationScaffolding(path: path, before: before)
        }
    }

    /// An ancestor is clean only if absent now, or still names its pre-operation identity. A
    /// failed post-observation after a known identity or known absence is always uncertain.
    /// If both observations are inaccessible, it is relevant only when Foundation returned a
    /// path below that ancestor; otherwise it does not prove an unrelated inaccessible path changed.
    static func unprovenFoundationScaffolding(
        _ observations: [ExportArtifactFoundationScaffolding],
        result: Result<ExportArtifactStagingDirectory, ExportArtifactStagingRefusal>,
        hooks: ExportArtifactWriterHooks
    ) -> [URL] {
        let returnedPath: String? = switch result {
        case let .success(directory): directory.path
        case let .failure(refusal):
            refusal.removableDirectory?.path ?? refusal.reportedURL?.path(percentEncoded: false)
        }
        return observations.compactMap { observation in
            switch hooks.noFollowStatus(observation.path, step: .inspectFoundationScaffolding) {
            case let .success(status):
                if case let .identity(before) = observation.before,
                   WorkspaceFileSystemIdentity(exportStatus: status) == before { return nil }
            case let .failure(failure):
                guard failure.code != ENOENT else { return nil }
                if case .unobservable = observation.before,
                   returnedPath.map({ pathLies($0, inside: observation.path, caseSensitive: true) }) != true
                {
                    return nil
                }
            }
            return WorkspaceLiteralFileURL.fileURL(path: observation.path, isDirectory: true)
        }
    }
}
