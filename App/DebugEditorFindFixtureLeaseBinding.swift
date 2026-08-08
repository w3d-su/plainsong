#if DEBUG
    import Darwin
    import Foundation

    extension DebugEditorFindFixtureLease {
        struct WorkspaceBinding: Codable, Equatable {
            private let formatVersion: Int
            private let workspaceDevice: UInt64
            private let workspaceInode: UInt64
            private let ownershipMarkerName: String
            private let ownershipMarkerDevice: UInt64
            private let ownershipMarkerInode: UInt64

            init(
                workspaceIdentity: DebugEditorFindFixture.EntryIdentity,
                ownershipMarkerName: String,
                ownershipMarkerIdentity: DebugEditorFindFixture.EntryIdentity
            ) {
                formatVersion = 1
                workspaceDevice = UInt64(
                    truncatingIfNeeded: workspaceIdentity.device
                )
                workspaceInode = UInt64(
                    truncatingIfNeeded: workspaceIdentity.inode
                )
                self.ownershipMarkerName = ownershipMarkerName
                ownershipMarkerDevice = UInt64(
                    truncatingIfNeeded: ownershipMarkerIdentity.device
                )
                ownershipMarkerInode = UInt64(
                    truncatingIfNeeded: ownershipMarkerIdentity.inode
                )
            }

            func matchesWorkspace(at workspaceURL: URL) throws -> Bool {
                guard let identity = validatedIdentity,
                      let workspaceStatus =
                      try DebugEditorFindFixture.entryStatus(at: workspaceURL),
                      DebugEditorFindFixture.fileType(of: workspaceStatus)
                      == mode_t(S_IFDIR),
                      DebugEditorFindFixture.identity(of: workspaceStatus)
                      == identity.workspace
                else {
                    return false
                }
                let markerURL = workspaceURL.appendingPathComponent(
                    identity.ownershipMarkerName,
                    isDirectory: false
                )
                guard let markerStatus =
                    try DebugEditorFindFixture.entryStatus(at: markerURL),
                    DebugEditorFindFixture.fileType(of: markerStatus)
                    == mode_t(S_IFREG)
                else {
                    return false
                }
                return DebugEditorFindFixture.identity(of: markerStatus)
                    == identity.ownershipMarker
            }

            var validatedIdentity: EditorFindFixtureWorkspaceIdentity? {
                guard formatVersion == 1,
                      isSafeOwnershipMarkerName
                else {
                    return nil
                }
                let workspaceDeviceValue = dev_t(
                    truncatingIfNeeded: workspaceDevice
                )
                let workspaceInodeValue = ino_t(
                    truncatingIfNeeded: workspaceInode
                )
                let markerDeviceValue = dev_t(
                    truncatingIfNeeded: ownershipMarkerDevice
                )
                let markerInodeValue = ino_t(
                    truncatingIfNeeded: ownershipMarkerInode
                )
                guard UInt64(truncatingIfNeeded: workspaceDeviceValue)
                    == workspaceDevice,
                    UInt64(truncatingIfNeeded: workspaceInodeValue)
                    == workspaceInode,
                    UInt64(truncatingIfNeeded: markerDeviceValue)
                    == ownershipMarkerDevice,
                    UInt64(truncatingIfNeeded: markerInodeValue)
                    == ownershipMarkerInode
                else {
                    return nil
                }
                return EditorFindFixtureWorkspaceIdentity(
                    workspace: DebugEditorFindFixture.EntryIdentity(
                        device: workspaceDeviceValue,
                        inode: workspaceInodeValue
                    ),
                    ownershipMarkerName: ownershipMarkerName,
                    ownershipMarker: DebugEditorFindFixture.EntryIdentity(
                        device: markerDeviceValue,
                        inode: markerInodeValue
                    )
                )
            }

            private var isSafeOwnershipMarkerName: Bool {
                let safeScalars = ownershipMarkerName.unicodeScalars.filter { scalar in
                    CharacterSet.alphanumerics.contains(scalar)
                        || scalar == "-"
                        || scalar == "_"
                        || scalar == "."
                }
                return ownershipMarkerName.hasPrefix(
                    DebugEditorFindFixture.ownershipMarkerFilePrefix
                )
                    && ownershipMarkerName.count <= 128
                    && String(String.UnicodeScalarView(safeScalars))
                    == ownershipMarkerName
            }
        }
    }
#endif
