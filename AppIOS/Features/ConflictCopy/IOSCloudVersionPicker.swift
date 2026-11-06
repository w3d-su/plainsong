import MarkdownCore
import SwiftUI
import WorkspaceKitIOS

struct IOSCloudVersionRequest: Identifiable {
    let id = UUID()
    let documentID: IOSDocumentIdentity
}

struct IOSCloudVersionPicker: View {
    let documentID: IOSDocumentIdentity
    let load: (IOSDocumentIdentity) async throws -> IOSCloudVersionReview
    let apply: (UUID, IOSCloudVersionReview) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var review: IOSCloudVersionReview?
    @State private var selected: IOSCloudVersionChoice?
    @State private var confirming = false
    @State private var applying = false
    @State private var error: String?
    @State private var refresh = UUID()

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Text(error).foregroundStyle(.red)
                    Button("Read Versions Again") { refresh = UUID() }
                } else if let review {
                    ForEach(Array(review.choices.enumerated()), id: \.element.id) { index, version in
                        Button {
                            selected = version
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(version.isCurrent ? "Current iCloud Version" : "Conflicting Version \(index)")
                                    if let device = version.device { Text(device).font(.caption) }
                                    if let date = version.date { Text(date.formatted()).font(.caption) }
                                }
                                Spacer()
                                if selected?.id == version.id { Image(systemName: "checkmark") }
                            }
                        }
                        .accessibilityAddTraits(selected?.id == version.id ? .isSelected : [])
                    }
                    if let selected {
                        Section("Preview") {
                            Text(selected.source.isEmpty ? "(Empty document)" : String(selected.source.prefix(4000)))
                                .font(.body.monospaced())
                            if selected.source.prefix(4001).count > 4000 {
                                NavigationLink("Read Full Version") {
                                    ScrollView {
                                        Text(selected.source).font(.body.monospaced()).textSelection(.enabled).padding()
                                    }
                                    .navigationTitle("Version Contents")
                                }
                            }
                        }
                        Button("Keep This Version") { confirming = true }
                    }
                } else {
                    ProgressView("Reading versions…")
                }
            }
            .disabled(applying)
            .navigationTitle("iCloud Versions")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(applying)
                }
            }
            .interactiveDismissDisabled(applying)
            .confirmationDialog("Use this version for the original document?", isPresented: $confirming) {
                Button("Use Selected Version", role: .destructive) {
                    guard let review, let selected, !applying else { return }
                    applying = true
                    Task {
                        defer { applying = false }
                        do {
                            try await apply(selected.id, review)
                            dismiss()
                        } catch {
                            self.error = IOSOperationFeedback.message(for: error)
                        }
                    }
                }
            } message: {
                Text(
                    "Your current editor text will be kept in Recovered Drafts. The other listed iCloud versions will be marked resolved."
                )
            }
        }
        .task(id: refresh) {
            review = nil
            selected = nil
            error = nil
            do {
                let loaded = try await load(documentID)
                try Task.checkCancellation()
                review = loaded
            } catch {
                if !Task.isCancelled { self.error = IOSOperationFeedback.message(for: error) }
            }
        }
    }
}
