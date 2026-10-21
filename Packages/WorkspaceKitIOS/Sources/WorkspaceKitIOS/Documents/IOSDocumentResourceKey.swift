import Foundation
import WorkspaceCore

/// One provider resource, or one exact path when the provider gave no stable id.
///
/// Unicode spelling is the UTF-8 bytes of `relativePath`. Swift string equality is not
/// the authority, and a shared root URL is not a shared writer.
struct IOSDocumentResourceKey: Hashable, Sendable {
    enum Discriminator: Hashable, Sendable {
        case resource(Data)
        case unscopedPath(Data)
    }

    let workspaceID: UUID
    let discriminator: Discriminator

    init(location: IOSFileLocation) {
        workspaceID = location.workspaceID.rawValue
        if let resourceID = location.resourceID {
            discriminator = .resource(resourceID.rawValue)
        } else {
            discriminator = .unscopedPath(Data(location.relativePath.utf8))
        }
    }
}
