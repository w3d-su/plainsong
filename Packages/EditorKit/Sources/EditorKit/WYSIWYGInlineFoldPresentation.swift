import AppKit
import Foundation

/// Presentation selector used by source mode and the Experimental WYSIWYG path.
/// Link folding remains on a separate development opt-in until its L1-L9 gates pass.
public enum MarkdownEditorDevelopmentPresentation: Equatable, Sendable {
    case source
    case inlineFoldReveal
    /// Link-folding sub-gate opt-in. The App must not select this case until L1-L9 pass.
    case inlineFoldRevealWithLinkFolding

    var enablesInlineFoldReveal: Bool {
        self != .source
    }

    var enablesLinkFolding: Bool {
        self == .inlineFoldRevealWithLinkFolding
    }
}

struct WYSIWYGInlineFoldPresentation {
    static let foldedDelimiterAttribute = NSAttributedString.Key("app.plainsong.wysiwyg.foldedDelimiter")

    let theme: MarkdownSyntaxTheme
    let baseFont: NSFont

    func apply(
        plan: WYSIWYGFoldPlan,
        visibleRange: NSRange,
        to attributed: NSMutableAttributedString
    ) {
        for region in plan.regions where Self.includes(region.kind, linkFoldingEnabled: plan.linkFoldingEnabled) {
            applyContentAttributes(for: region, visibleRange: visibleRange, to: attributed)
        }

        Self.applyFoldedDelimiterAttributes(plan: plan, visibleRange: visibleRange, to: attributed)
    }

    static func applyFoldedDelimiterAttributes(
        plan: WYSIWYGFoldPlan,
        visibleRange: NSRange,
        to attributed: NSMutableAttributedString
    ) {
        for range in plan.regions
            .filter({ Self.includes($0.kind, linkFoldingEnabled: plan.linkFoldingEnabled) && !$0.isRevealed })
            .flatMap(\.foldRanges)
        {
            guard let localRange = range.intersection(with: visibleRange, offsetBy: -visibleRange.location),
                  NSMaxRange(localRange) <= attributed.length
            else {
                continue
            }

            attributed.addAttributes(Self.foldedDelimiterAttributes, range: localRange)
        }
    }

    static func includes(_ kind: WYSIWYGFoldRegion.Kind, linkFoldingEnabled: Bool) -> Bool {
        switch kind {
        case .heading, .strong, .emphasis, .strikethrough, .inlineCode:
            true
        case .link:
            linkFoldingEnabled
        }
    }

    static func containsFoldedDelimiterAttributes(_ attributes: [NSAttributedString.Key: Any]) -> Bool {
        attributes[foldedDelimiterAttribute] as? Bool == true
    }

    private func applyContentAttributes(
        for region: WYSIWYGFoldRegion,
        visibleRange: NSRange,
        to attributed: NSMutableAttributedString
    ) {
        guard let localContentRange = region.contentRange.intersection(
            with: visibleRange,
            offsetBy: -visibleRange.location
        ), NSMaxRange(localContentRange) <= attributed.length else {
            return
        }

        switch region.kind {
        case .strikethrough:
            attributed.addAttribute(
                .strikethroughStyle,
                value: NSUnderlineStyle.single.rawValue,
                range: localContentRange
            )

        case .inlineCode:
            attributed.addAttributes(
                [
                    .font: baseFont,
                    .foregroundColor: theme.codeColor,
                    .backgroundColor: theme.codeBackgroundColor,
                ],
                range: localContentRange
            )

        case .heading, .strong, .emphasis, .link:
            return
        }
    }

    private static var foldedDelimiterAttributes: [NSAttributedString.Key: Any] {
        [
            foldedDelimiterAttribute: true,
        ]
    }
}

private extension NSRange {
    func intersection(with other: NSRange, offsetBy offset: Int) -> NSRange? {
        let intersection = NSIntersectionRange(self, other)
        guard intersection.length > 0 else {
            return nil
        }
        return intersection.offset(by: offset)
    }
}
