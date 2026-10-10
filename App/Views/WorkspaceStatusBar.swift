import MarkdownCore
import SwiftUI

/// Quiet bottom bar with document counts; the file type lives in the jump bar.
struct WorkspaceStatusBar: View {
    let statistics: TextStatistics

    var body: some View {
        HStack(spacing: 6) {
            Text("\(statistics.lineCount) lines")
            Text("·").foregroundStyle(.tertiary)
            Text("\(statistics.wordCount) words")
            Text("·").foregroundStyle(.tertiary)
            Text("\(statistics.characterCount) characters")
            Spacer()
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 24)
        .accessibilityElement(children: .combine)
    }
}
