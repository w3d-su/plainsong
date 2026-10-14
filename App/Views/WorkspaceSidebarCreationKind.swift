enum WorkspaceSidebarCreationKind {
    case file
    case folder

    var title: String {
        switch self {
        case .file:
            "New File"
        case .folder:
            "New Folder"
        }
    }

    var prompt: String {
        switch self {
        case .file:
            "Enter a name for the new file."
        case .folder:
            "Enter a name for the new folder."
        }
    }

    var defaultName: String {
        switch self {
        case .file:
            "Untitled.md"
        case .folder:
            "New Folder"
        }
    }
}
