import SwiftUI

struct IOSRecentAccessList: View {
    @ObservedObject var presenter: IOSRecentAccessPresenter

    var body: some View {
        List {
            if let error = presenter.errorMessage {
                Text(error).foregroundStyle(.secondary)
            }
            if presenter.rows.isEmpty {
                Text("No Recent Files or Folders").foregroundStyle(.secondary)
            }
            ForEach(presenter.rows) { row in
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        presenter.open(recordID: row.id)
                    } label: {
                        Label(row.displayName, systemImage: row.scope == .directory ? "folder" : "doc.text")
                    }
                    .disabled(presenter.isBusy || row.status != .available)
                    .accessibilityIdentifier("plainsong.ios.recent.open.\(row.id.uuidString)")
                    Text(row.detail).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Choose Again") { presenter.chooseAgain(recordID: row.id) }
                            .disabled(presenter.isBusy)
                        Spacer()
                        Button("Remove Record", role: .destructive) { presenter.removeRecord(recordID: row.id) }
                            .accessibilityHint("Remove this recent item from the list. The file or folder is kept.")
                    }
                    if presenter.openingRecordID == row.id {
                        ProgressView("Opening…")
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .contain)
            }
        }
        .navigationTitle("Recent Files and Folders")
        .onAppear { presenter.reload() }
        .onDisappear { presenter.cancelPendingOpen() }
    }
}
