import SwiftUI

extension View {
    /// Liquid Glass on macOS 26+, the regular material before it.
    ///
    /// Standard controls (toolbars, sidebars, segmented pickers) pick up glass on their own;
    /// this is only for Plainsong's own floating surfaces such as notice cards and the
    /// sidebar's bottom controls.
    @ViewBuilder
    func plainsongGlass(tint: Color? = nil, in shape: some Shape) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular.tint(tint), in: shape)
        } else {
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
}
