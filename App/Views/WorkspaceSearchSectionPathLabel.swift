import SwiftUI

/// File name first, parent folder dimmed after it, as in Xcode's Find navigator.
struct WorkspaceSearchSectionPathLabel: View {
    let relativePath: String

    var body: some View {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)
        let fileName = components.last.map(String.init) ?? relativePath
        let folder = components.dropLast().joined(separator: "/")

        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(fileName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .layoutPriority(1)
            if !folder.isEmpty {
                Text(folder)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .textCase(nil)
        .help(relativePath)
    }
}
