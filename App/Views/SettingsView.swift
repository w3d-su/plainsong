import SwiftUI

/// Settings window placeholder. Real preference panes land in M5 (agent.md §11).
struct SettingsView: View {
    var body: some View {
        Form {
            Text("Settings arrive in M5 (agent.md §11).")
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 420)
    }
}
