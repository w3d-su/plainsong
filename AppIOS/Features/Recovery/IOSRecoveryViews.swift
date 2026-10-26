import SwiftUI
import WorkspaceKitIOS

struct IOSRecoveryEntry: View {
    @ObservedObject var controller: IOSRecoveryController
    @State private var presentedID: UUID?

    var body: some View {
        Button {
            controller.present()
        } label: {
            Label("Recovered Drafts", systemImage: "clock.arrow.circlepath")
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityIdentifier("plainsong.ios.recovery.open")
        .sheet(isPresented: $controller.isPresented, onDismiss: {
            controller.didDismiss(presentedID)
            presentedID = nil
        }) {
            if let id = controller.presentationID {
                IOSRecoveryView(controller: controller)
                    .interactiveDismissDisabled(controller.isRestoring)
                    .onAppear {
                        if controller.didAppear(id) {
                            presentedID = id
                        }
                    }
            }
        }
    }
}

private struct IOSRecoveryView: View {
    @ObservedObject var controller: IOSRecoveryController

    var body: some View {
        NavigationStack {
            Group {
                if let record = controller.detail {
                    detail(record)
                } else {
                    draftList
                }
            }
            .navigationTitle("Recovered Drafts")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { controller.isPresented = false }
                        .disabled(controller.isRestoring)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let error = controller.errorMessage {
                    Text(error).font(.callout).padding().accessibilityIdentifier("plainsong.ios.recovery.error")
                }
            }
        }
        .task { await controller.refresh() }
        .sheet(item: Binding(get: { controller.pickerRequest }, set: { request in
            if request == nil, !controller.isRestoring {
                controller.cancelPicker()
            }
        })) { request in
            IOSProductionDocumentPicker(request: IOSProductionPickerRequest(scope: .directory)) { urls in
                controller.completePicker(request, urls: urls)
            }
        }
    }

    private var draftList: some View {
        List {
            if controller.isLoading {
                ProgressView("Reading recovery drafts…")
            }
            if controller.records.isEmpty, !controller.isLoading {
                Text("No recovered drafts. Drafts kept after an interrupted save appear here.")
            }
            if controller.corruptCount > 0 {
                Text("\(controller.corruptCount) recovery record(s) could not be read. They were kept for recovery.")
                    .foregroundStyle(.secondary)
            }
            ForEach(controller.records, id: \.recordID) { record in
                Button {
                    Task { await controller.select(record.recordID) }
                } label: {
                    VStack(alignment: .leading) {
                        Text(Self.title(record))
                        Text("Draft version \(record.revisionVersion) · \(Self.reason(record.reason))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 44)
                }
            }
            Button("Refresh") { Task { await controller.refresh() } }
        }
    }

    private func detail(_ record: IOSRecoveryRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Button("Back to Drafts", action: controller.backToList).disabled(controller.isRestoring)
                Text(Self.title(record)).font(.headline)
                Text(
                    "Read-only draft. Restore creates a new file in your chosen folder and keeps this recovery draft."
                )
                .font(.callout)
                Text(record.source)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("plainsong.ios.recovery.source")
                Button("Restore as New File", action: controller.requestRestore)
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.isRestoring)
                    .accessibilityIdentifier("plainsong.ios.recovery.restore")
                if controller.isRestoring {
                    ProgressView("Restoring…")
                }
            }
            .padding()
        }
    }

    private static func title(_ record: IOSRecoveryRecord) -> String {
        let path = String(data: record.relativePathUTF8, encoding: .utf8) ?? ""
        return path.split(separator: "/").last.map(String.init) ?? "Recovered draft"
    }

    private static func reason(_ reason: IOSRecoveryReason) -> String {
        switch reason {
        case .externalConflict: "File changed elsewhere"
        case .backgroundDeadline: "Interrupted background save"
        case .closeIncomplete: "Document could not close"
        case .saveIndeterminate: "Save could not be confirmed"
        }
    }
}
