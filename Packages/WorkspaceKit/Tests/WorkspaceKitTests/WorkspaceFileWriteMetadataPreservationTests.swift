import Darwin
import Foundation
@testable import WorkspaceKit
import XCTest

/// A save publishes a new inode, so everything the replaced file carried besides its bytes
/// and rwx bits used to vanish at the first autosave. Extended attributes (Finder tags
/// included), the extended ACL and the creation date now follow the content.
extension WorkspaceAnchoredFileSystemTests {
    func testSavePreservesExtendedAttributesIncludingFinderTags() throws {
        let fixture = try makeWriteFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let tags = try PropertyListSerialization.data(
            fromPropertyList: ["Blue\n4", "Draft"],
            format: .binary,
            options: 0
        )
        try setExtendedAttribute("com.apple.metadata:_kMDItemUserTags", tags, at: fixture.destination)
        try setExtendedAttribute("org.plainsong.test", Data("kept".utf8), at: fixture.destination)
        try setExtendedAttribute("org.plainsong.empty", Data(), at: fixture.destination)

        let outcome = try write(to: fixture, expecting: .existing(XCTUnwrap(fixture.originalIdentity)))

        XCTAssertNotNil(requireDurable(outcome))
        XCTAssertNotEqual(try writeFileIdentity(at: fixture.destination), fixture.originalIdentity)
        XCTAssertEqual(try extendedAttribute("com.apple.metadata:_kMDItemUserTags", at: fixture.destination), tags)
        XCTAssertEqual(try extendedAttribute("org.plainsong.test", at: fixture.destination), Data("kept".utf8))
        XCTAssertEqual(try extendedAttribute("org.plainsong.empty", at: fixture.destination), Data())
        let tagNames = try URL(fileURLWithPath: fixture.destination.path)
            .resourceValues(forKeys: [.tagNamesKey]).tagNames
        XCTAssertEqual(tagNames, ["Blue", "Draft"])
        try assertNoWriteArtifacts(for: fixture)
    }

    func testSavePreservesTheCreationDate() throws {
        let fixture = try makeWriteFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let created = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: fixture.destination.path)

        let outcome = try write(to: fixture, expecting: .existing(XCTUnwrap(fixture.originalIdentity)))

        XCTAssertNotNil(requireDurable(outcome))
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.destination.path)
        let restored = try XCTUnwrap(attributes[.creationDate] as? Date)
        XCTAssertEqual(restored.timeIntervalSince1970, created.timeIntervalSince1970, accuracy: 1)
    }

    func testSavePreservesTheExtendedACL() throws {
        let fixture = try makeWriteFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+a", "everyone allow readattr,readextattr", fixture.destination.path]
        try chmod.run()
        chmod.waitUntilExit()
        try XCTSkipIf(chmod.terminationStatus != 0, "This volume does not support extended ACLs")

        let outcome = try write(to: fixture, expecting: .existing(XCTUnwrap(fixture.originalIdentity)))

        XCTAssertNotNil(requireDurable(outcome))
        let published = try XCTUnwrap(fixture.destination.path.withCString { acl_get_file($0, ACL_TYPE_EXTENDED) })
        defer { acl_free(UnsafeMutableRawPointer(published)) }
        let text = try XCTUnwrap(acl_to_text(published, nil))
        defer { acl_free(UnsafeMutableRawPointer(text)) }
        let description = String(cString: text)
        XCTAssertTrue(description.contains("allow") && description.contains("readextattr"), description)
    }

    func testSaveToAMissingDestinationAppliesTheUmask() throws {
        let fixture = try makeWriteFixture(originalText: nil)
        defer { try? FileManager.default.removeItem(at: fixture.parent) }

        let outcome = write(to: fixture, expecting: .missing)

        XCTAssertNotNil(requireDurable(outcome))
        let mode = try noFollowStatus(at: fixture.destination).st_mode & mode_t(0o777)
        XCTAssertEqual(mode, mode_t(0o666) & ~Self.currentUmask)
    }

    func testOnlySystemOwnedAttributesAreLeftBehind() {
        for name in ["com.apple.macl", "com.apple.provenance", "com.apple.decmpfs", "com.apple.system.Security"] {
            XCTAssertFalse(WorkspaceAnchoredFileSystem.isPreservedExtendedAttribute(name), name)
        }
        for name in [
            "com.apple.metadata:_kMDItemUserTags",
            "com.apple.FinderInfo",
            "com.apple.quarantine",
            "com.apple.metadata:kMDItemWhereFroms",
            "org.example.custom",
        ] {
            XCTAssertTrue(WorkspaceAnchoredFileSystem.isPreservedExtendedAttribute(name), name)
        }
    }

    /// Reads the process umask without leaving it changed.
    static var currentUmask: mode_t {
        let mask = umask(0o022)
        umask(mask)
        return mask
    }

    private func setExtendedAttribute(_ name: String, _ value: Data, at url: URL) throws {
        let result = value.withUnsafeBytes { bytes in
            url.path.withCString { setxattr($0, name, bytes.baseAddress, bytes.count, 0, XATTR_NOFOLLOW) }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func extendedAttribute(_ name: String, at url: URL) throws -> Data? {
        let size = url.path.withCString { getxattr($0, name, nil, 0, 0, XATTR_NOFOLLOW) }
        guard size >= 0 else { return nil }
        var value = [UInt8](repeating: 0, count: max(size, 1))
        let read = url.path.withCString { getxattr($0, name, &value, size, 0, XATTR_NOFOLLOW) }
        guard read == size else { throw POSIXError(.EIO) }
        return Data(value.prefix(size))
    }
}
