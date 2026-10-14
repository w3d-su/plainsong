import SwiftUI

extension View {
    /// Liquid Glass on macOS 26+, the regular material before it.
    ///
    /// Standard controls (toolbars, sidebars, segmented pickers) pick up glass on their own;
    /// this is only for Plainsong's own floating surfaces such as notice cards and the
    /// sidebar's bottom controls. The glass branch also needs the macOS 26 SDK (Swift 6.2),
    /// so older toolchains such as CI's Xcode 16 compile only the material fallback.
    @ViewBuilder
    func plainsongGlass(tint: Color? = nil, in shape: some Shape) -> some View {
        #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                glassEffect(.regular.tint(tint), in: shape)
            } else {
                materialBackground(tint: tint, in: shape)
            }
        #else
            materialBackground(tint: tint, in: shape)
        #endif
    }

    private func materialBackground(tint: Color?, in shape: some Shape) -> some View {
        background {
            ZStack {
                shape.fill(.regularMaterial)
                if let tint {
                    shape.fill(tint)
                }
            }
        }
    }
}
