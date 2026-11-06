import Foundation
import MarkdownCore

/// A review belongs to one open document and revision. Provider identities and URLs
/// stay private. The UI returns only a choice from this review.
public struct IOSCloudVersionReview: Identifiable, Sendable {
    public let id = UUID()
    public let revision: IOSDocumentRevision
    public let choices: [IOSCloudVersionChoice]
}

public struct IOSCloudVersionChoice: Identifiable, Sendable {
    public let id = UUID()
    public let isCurrent: Bool
    public let device: String?
    public let date: Date?
    public let source: String
    let key: IOSCloudVersionKey
}

/// Foundation specifies that a version's persistent identifier is immutable.
struct IOSCloudVersionKey: Hashable, @unchecked Sendable {
    let identifier: AnyHashable
    let isCurrent: Bool
}

/// Constructed and used only inside one coordinated accessor.
struct IOSCloudFileVersion {
    let key: IOSCloudVersionKey
    let url: URL
    var needsDownload = false
    let device: String?
    let date: Date?
    let install: (URL) throws -> Void
    let resolve: () -> Void

    static func versions(at url: URL) throws -> [Self] {
        guard let current = NSFileVersion.currentVersionOfItem(at: url) else {
            throw IOSDocumentFailure.unavailable
        }
        let others = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
        return try ([current] + others).enumerated().map { index, version in
            guard let identifier = version.persistentIdentifier as? AnyHashable else {
                throw IOSDocumentFailure.unavailable
            }
            let isCurrent = index == 0
            return Self(
                key: IOSCloudVersionKey(identifier: identifier, isCurrent: isCurrent),
                url: isCurrent ? url : version.url, needsDownload: !isCurrent && !version.hasLocalContents,
                device: version.localizedNameOfSavingComputer,
                date: version.modificationDate,
                install: { _ = try version.replaceItem(at: $0, options: []) },
                resolve: {
                    version.isResolved = true
                    // Resolution succeeded even if iCloud defers reclaiming the historical version.
                    try? version.remove()
                }
            )
        }
    }
}

enum IOSCloudVersionIO {
    static func choices(from versions: [IOSCloudFileVersion], limit: Int) throws -> [IOSCloudVersionChoice] {
        var remaining = limit
        return try versions.map { version in
            guard !version.needsDownload else { throw IOSDocumentFailure.access(.downloading) }
            let bytes = try read(version.url, limit: remaining)
            remaining -= bytes.count
            guard let source = IOSDocumentTextCodec.decode(bytes) else {
                throw IOSDocumentFailure.access(.unsupportedType)
            }
            return IOSCloudVersionChoice(
                isCurrent: version.key.isCurrent, device: version.device, date: version.date,
                source: source, key: version.key
            )
        }
    }

    /// The write coordinator excludes competing changes while rechecking the complete
    /// version set, installing the chosen bytes and resolving the reviewed conflicts.
    static func apply(
        _ selected: UUID, review: IOSCloudVersionReview, at original: URL,
        versions: [IOSCloudFileVersion], limit: Int, cancellation: Progress
    ) throws {
        let fresh = try choices(from: versions, limit: limit)
        let reviewed = Dictionary(grouping: review.choices, by: \.key)
        guard let chosen = review.choices.first(where: { $0.id == selected }),
              let version = versions.first(where: { $0.key == chosen.key }),
              Set(fresh.map(\.key)).count == fresh.count, reviewed.count == fresh.count,
              fresh.allSatisfy({ item in
                  guard let matches = reviewed[item.key], matches.count == 1, let expected = matches.first else {
                      return false
                  }
                  return ExactSourceText.matches(item.source, expected.source)
              }), !cancellation.isCancelled else { throw IOSDocumentFailure.documentChanged }
        if !chosen.isCurrent {
            try version.install(original)
        }
        guard try read(original, limit: limit).elementsEqual(chosen.source.utf8) else {
            throw IOSDocumentFailure.indeterminate
        }
        guard !cancellation.isCancelled else { throw IOSDocumentFailure.indeterminate }
        for other in versions where !other.key.isCurrent {
            other.resolve()
        }
    }

    private static func read(_ url: URL, limit: Int) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var result = Data()
        while let chunk = try file.read(upToCount: min(65536, limit - result.count + 1)), !chunk.isEmpty {
            guard chunk.count <= limit - result.count else { throw IOSDocumentFailure.access(.tooLarge) }
            result.append(chunk)
        }
        return result
    }

    static func checkedURL(_ url: URL, expected: URL, root: URL) throws -> URL {
        let proven = try IOSWorkspaceRootAuthority.proveExisting(url, root: root)
        guard IOSWorkspacePathAuthority.sameFile(url, expected),
              try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false
        else { throw IOSDocumentFailure.documentChanged }
        return proven
    }
}

public extension IOSUIDocumentStore {
    func reviewCloudVersions(for identity: IOSDocumentIdentity) async throws -> IOSCloudVersionReview {
        let entry = try requireEntry(identity)
        let revision = try cloudRevision(entry)
        let url = entry.location.fileURL, root = entry.lease.grant.rootURL, limit = maximumExternalBytes
        let port = IOSSystemWorkspaceFilePort()
        let enumerate = cloudVersionsAtURL
        let pending = try await port.coordinate(url: url, reading: [.withoutChanges]) { urlIn in
            let proven = try IOSCloudVersionIO.checkedURL(urlIn, expected: url, root: root)
            return try enumerate(proven).filter(\.needsDownload).map(\.url)
        }
        // Apple supplies the version URLs. Coordinate each download outside the
        // original item's accessor, then enumerate again for the reviewed bytes.
        for versionURL in pending {
            guard try cloudRevision(entry) == revision else { throw IOSDocumentFailure.documentChanged }
            try await port.coordinate(url: versionURL, reading: []) { _ in () }
        }
        let choices = try await port.coordinate(url: url, reading: [.withoutChanges]) { urlIn in
            let proven = try IOSCloudVersionIO.checkedURL(urlIn, expected: url, root: root)
            return try IOSCloudVersionIO.choices(from: enumerate(proven), limit: limit)
        }
        guard try cloudRevision(entry) == revision else { throw IOSDocumentFailure.documentChanged }
        return IOSCloudVersionReview(revision: revision, choices: choices)
    }

    func applyCloudVersion(_ selected: UUID, from review: IOSCloudVersionReview) async throws {
        let entry = try requireEntry(review.revision.documentID)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            entry.queue.enqueue {
                do {
                    guard try self.cloudRevision(entry) == review.revision
                    else { throw IOSDocumentFailure.sourceChanged }
                    _ = try await self.persistStableRecovery(entry, reason: .externalConflict)
                    guard try self.cloudRevision(entry) == review.revision
                    else { throw IOSDocumentFailure.sourceChanged }
                    let cancellation = Progress(totalUnitCount: 1)
                    entry.cloudResolution = cancellation
                    defer { entry.cloudResolution = nil }
                    let url = entry.location.fileURL, root = entry.lease.grant.rootURL,
                        limit = self.maximumExternalBytes
                    let enumerate = self.cloudVersionsAtURL
                    try await IOSSystemWorkspaceFilePort().coordinate(url: url, writing: .forMerging) { urlIn in
                        let proven = try IOSCloudVersionIO.checkedURL(urlIn, expected: url, root: root)
                        try IOSCloudVersionIO.apply(
                            selected, review: review, at: proven, versions: enumerate(proven),
                            limit: limit, cancellation: cancellation
                        )
                    }
                    guard try self.cloudRevision(entry) == review.revision
                    else { throw IOSDocumentFailure.documentChanged }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func cloudRevision(_ entry: IOSDocumentEntry) throws -> IOSDocumentRevision {
        guard entry.hasUnresolvedVersions, case .unavailable(_, .conflict) = entry.state,
              !entry.isClosing, !entry.isRetiring, !entry.portClosed, let session = entry.session,
              guardCurrentAuthority(entry, generation: entry.accessGeneration)
        else { throw IOSDocumentFailure.documentChanged }
        return IOSDocumentRevision(documentID: entry.identity, version: session.version)
    }
}
