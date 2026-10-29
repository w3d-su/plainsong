import AppKit
import MarkdownCore
import os

public extension MarkdownSyntaxTheme {
    /// Records Increase Contrast for dynamic theme colors. The color provider reads the
    /// stored flag and does not call `NSWorkspace` or hop to the main thread.
    static func noteAccessibilityIncreaseContrast(_ enabled: Bool) {
        EditorThemeDynamicColor.increaseContrast.withLock { $0 = enabled }
    }

    /// Resolves a validated theme onto the built-in palette. Omitted slots keep the built-in
    /// dynamic color. An omitted `gutter` stays `nil` so the gutter track keeps following the
    /// editor background, which is what the gutter drew before this slot existed.
    static func resolving(
        _ document: CustomThemeDocument,
        builtIn fallback: MarkdownEditorTheme = .standard
    ) -> MarkdownSyntaxTheme {
        #if DEBUG
            EditorThemeResolutionProbe.recordResolve()
        #endif
        let base = MarkdownSyntaxTheme.builtIn(fallback)
        let light = document.light.editor
        let dark = document.dark?.editor
        let darkOmitted = document.dark == nil

        func slot(_ key: String, builtIn color: NSColor) -> NSColor {
            let darkHex = darkOmitted ? nil : dark?[key]
            // AppKit keeps the first provider registered for a name, so the name has to
            // include the built-in fallback. Otherwise a later graphite resolve would
            // keep the standard colors (or the reverse) for every omitted slot.
            // Increase Contrast is not part of the name: the provider reads it when the
            // color is resolved, and a second registration would be ignored.
            let name = [
                "plainsong.theme",
                fallback.rawValue,
                document.id,
                key,
                light[key] ?? "-",
                darkOmitted ? "omit" : (darkHex ?? "-"),
            ].joined(separator: ".")
            return EditorThemeDynamicColor.resolving(
                lightHex: light[key],
                darkHex: darkHex,
                darkPaletteOmitted: darkOmitted,
                builtIn: color,
                name: name
            )
        }

        let specifiesGutter = light["gutter"] != nil || (!darkOmitted && dark?["gutter"] != nil)
        return MarkdownSyntaxTheme(
            textColor: slot("text", builtIn: base.textColor),
            mutedColor: slot("muted", builtIn: base.mutedColor),
            headingColor: slot("heading", builtIn: base.headingColor),
            linkColor: slot("link", builtIn: base.linkColor),
            codeColor: slot("code", builtIn: base.codeColor),
            codeBackgroundColor: slot("codeBackground", builtIn: base.codeBackgroundColor),
            frontmatterColor: slot("frontmatter", builtIn: base.frontmatterColor),
            frontmatterBackgroundColor: slot("frontmatterBackground", builtIn: base.frontmatterBackgroundColor),
            listMarkerColor: slot("listMarker", builtIn: base.listMarkerColor),
            tsxKeywordColor: slot("tsxKeyword", builtIn: base.tsxKeywordColor),
            tsxStringColor: slot("tsxString", builtIn: base.tsxStringColor),
            tsxTagColor: slot("tsxTag", builtIn: base.tsxTagColor),
            tsxAttributeColor: slot("tsxAttribute", builtIn: base.tsxAttributeColor),
            tsxPunctuationColor: slot("tsxPunctuation", builtIn: base.tsxPunctuationColor),
            backgroundColor: slot("background", builtIn: base.backgroundColor),
            selectionColor: slot("selection", builtIn: base.selectionColor),
            caretColor: slot("caret", builtIn: base.caretColor),
            gutterBackgroundColor: specifiesGutter ? slot("gutter", builtIn: base.backgroundColor) : nil
        )
    }
}

enum EditorThemeDynamicColor {
    static func resolving(
        lightHex: String?,
        darkHex: String?,
        darkPaletteOmitted: Bool,
        builtIn: NSColor,
        name: String
    ) -> NSColor {
        let hasLight = lightHex != nil
        let hasDark = !darkPaletteOmitted && darkHex != nil
        guard hasLight || hasDark else {
            return builtIn
        }

        let light = lightHex.flatMap(color(hex:))
        let dark = darkHex.flatMap(color(hex:))
        // The name includes the fallback and hex values, so replacing a theme registers a new color.
        // AppKit keeps the first provider registered for a name.
        return NSColor(name: NSColor.Name(name)) { appearance in
            if EditorThemeDynamicColor.increaseContrast.withLock({ $0 }) {
                return builtIn
            }
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            if isDark {
                return (darkPaletteOmitted || dark == nil) ? builtIn : (dark ?? builtIn)
            }
            return light ?? builtIn
        }
    }

    /// Written on the main actor when preferences start and when the setting changes.
    /// A dynamic color can be resolved on any thread, so this is not read from `NSWorkspace`.
    static let increaseContrast = OSAllocatedUnfairLock(initialState: false)

    static func color(hex: String) -> NSColor? {
        let digits = hex.dropFirst()
        guard digits.count == 6 || digits.count == 8, let value = UInt32(digits, radix: 16) else {
            return nil
        }
        let red, green, blue, alpha: CGFloat
        if digits.count == 6 {
            red = CGFloat((value >> 16) & 0xFF) / 255
            green = CGFloat((value >> 8) & 0xFF) / 255
            blue = CGFloat(value & 0xFF) / 255
            alpha = 1
        } else {
            red = CGFloat((value >> 24) & 0xFF) / 255
            green = CGFloat((value >> 16) & 0xFF) / 255
            blue = CGFloat((value >> 8) & 0xFF) / 255
            alpha = CGFloat(value & 0xFF) / 255
        }
        return NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

enum EditorSyntaxThemeChrome {
    @MainActor
    static func apply(
        _ theme: MarkdownSyntaxTheme,
        showsLineNumbers: Bool,
        font: NSFont,
        to textView: MarkdownSTTextView
    ) {
        if textView.backgroundColor != theme.backgroundColor {
            textView.backgroundColor = theme.backgroundColor
        }
        if textView.insertionPointColor != theme.caretColor {
            textView.insertionPointColor = theme.caretColor
        }
        // STTextView paints the selection in its own overlay, not selectedTextAttributes.
        if textView.editorSelectionColor != theme.selectionColor {
            textView.editorSelectionColor = theme.selectionColor
        }
        textView.setLineNumberGutterStyle(
            .init(showing: showsLineNumbers, syntaxTheme: theme, font: font)
        )
    }
}

#if DEBUG
    enum EditorThemeResolutionProbe {
        static let count = OSAllocatedUnfairLock(initialState: 0)

        static func recordResolve() {
            count.withLock { $0 += 1 }
        }
    }
#endif
