import Darwin

/// Retains ordinary directory permission checks when available, while allowing a
/// single-file grant to supply only the search access needed for document authority.
func openEditorImageAssetDirectory(
    parentDescriptor: Int32 = AT_FDCWD,
    path: String,
    noFollowAny: Bool = false
) -> Int32 {
    let flags = O_DIRECTORY | O_CLOEXEC | (noFollowAny ? O_NOFOLLOW_ANY : O_NOFOLLOW)
    let descriptor = path.withCString {
        Darwin.openat(parentDescriptor, $0, O_RDONLY | flags)
    }
    guard descriptor < 0, errno == EACCES || errno == EPERM else { return descriptor }
    return path.withCString {
        Darwin.openat(parentDescriptor, $0, O_SEARCH | flags)
    }
}
