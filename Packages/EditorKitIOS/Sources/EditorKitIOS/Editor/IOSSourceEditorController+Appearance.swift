import UIKit

extension IOSSourceEditorController {
    /// `.unspecified` follows the host. Light and dark force the text view and
    /// its gutter, then resolve dynamic colors against that style. Setting
    /// `overrideUserInterfaceStyle` alone does not update this view's traits
    /// before UIKit resolves `.systemBackground` and `.label`.
    public func applyInterfaceStyle(_ style: UIUserInterfaceStyle) {
        guard forcedInterfaceStyle != style else { return }
        forcedInterfaceStyle = style
        textView.installInterfaceStyle(style)
        textView.updateTraitsIfNeeded()
        applyThemeChrome()
    }

    func resolvedAppearanceColor(_ color: UIColor) -> UIColor {
        guard forcedInterfaceStyle != .unspecified else { return color }
        // A trait collection with only the style can leave `.systemBackground`
        // dynamic, so it flips back to the host. Bake the resolved components.
        let traits = textView.traitCollection.modifyingTraits { mutable in
            mutable.userInterfaceStyle = forcedInterfaceStyle
        }
        var baked = color
        traits.performAsCurrent {
            baked = Self.staticColor(color.resolvedColor(with: traits))
        }
        return baked
    }

    private static func staticColor(_ color: UIColor) -> UIColor {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        if color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            return UIColor(red: red, green: green, blue: blue, alpha: alpha)
        }
        var white: CGFloat = 0
        if color.getWhite(&white, alpha: &alpha) {
            return UIColor(white: white, alpha: alpha)
        }
        return UIColor(cgColor: color.cgColor)
    }

    func applyThemeChrome() {
        textView.backgroundColor = resolvedAppearanceColor(theme.background)
        applyLineNumberChrome()
        if textView.markedTextRange != nil {
            needsBaseStyle = true
            raisePresentationFloor()
            return
        }
        applyBaseTextStyle()
        raisePresentationFloor()
        scheduleHighlight()
    }
}
