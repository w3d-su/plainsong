import SwiftUI

/// Inline notice shown as a floating glass card above the editor.
///
/// Message leads and actions trail (primary action last), so every editor notice reads the
/// same way. The card sits in the layout rather than over the text, so it never hides
/// content.
struct NoticeBar<Actions: View>: View {
    enum Tone {
        case neutral
        case caution
        case critical

        var tint: Color {
            switch self {
            case .neutral:
                .secondary
            case .caution:
                .orange
            case .critical:
                .red
            }
        }

        var glassTint: Color? {
            switch self {
            case .neutral:
                nil
            case .caution, .critical:
                tint.opacity(0.18)
            }
        }
    }

    let tone: Tone
    let systemImage: String
    let message: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: systemImage)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tone.tint)
                .imageScale(.large)
                .accessibilityHidden(true)

            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                actions()
            }
            .controlSize(.small)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .plainsongGlass(tint: tone.glassTint, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .accessibilityElement(children: .contain)
    }
}
