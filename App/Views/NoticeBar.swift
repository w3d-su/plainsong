import SwiftUI

/// Inline notification bar shown above the editor (Safari/Xcode style).
///
/// Message leads and actions trail, so every editor notice reads the same way. The bar keeps
/// the window's bar material and only washes it with the tone color, so it stays legible on
/// both appearances and under Increase Contrast.
struct NoticeBar<Actions: View>: View {
    enum Tone {
        case caution
        case critical

        var tint: Color {
            switch self {
            case .caution:
                .orange
            case .critical:
                .red
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
        .padding(.vertical, 8)
        .background {
            ZStack {
                Rectangle().fill(.bar)
                Rectangle().fill(tone.tint.opacity(0.1))
            }
        }
        .accessibilityElement(children: .contain)
    }
}
