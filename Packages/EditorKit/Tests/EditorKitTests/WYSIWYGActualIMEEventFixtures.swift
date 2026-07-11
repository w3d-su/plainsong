import Carbon
import CoreGraphics
@testable import EditorKit
import Foundation

let actualIMEGateSource = "# 標題\n\n前綴 **粗體**、*斜體*、`程式` 後綴\n"
let actualIMELinkGateSource = "前綴 [連結文字](https://example.com/path) 後綴\n"
let actualIMEImageGateLiteral = "![縮圖](fixture.png)"
let actualIMEImageGateSource = "前綴 \(actualIMEImageGateLiteral) 後綴\n"

struct ActualIMEScript {
    let name: String
    let compositionSteps: [ActualIMECompositionStep]
    let commitKeys: [ActualIMEKey]
    let acceptableActiveCommitTexts: [String]
    let acceptableCommittedTexts: [String]

    static let zhuyin = ActualIMEScript(
        name: "Zhuyin",
        compositionSteps: [
            ActualIMECompositionStep(key: .w, acceptableInsertedTexts: ["ㄊ"]),
            ActualIMECompositionStep(key: .nine, acceptableInsertedTexts: ["ㄊㄞ"]),
            ActualIMECompositionStep(key: .six, acceptableInsertedTexts: ["台", "臺"]),
        ],
        commitKeys: [.space, .returnKey, .returnKey],
        acceptableActiveCommitTexts: ["台", "臺"],
        acceptableCommittedTexts: ["台", "臺"]
    )

    /// Toneless Pinyin "tai" + space commits the first candidate, which the macOS
    /// Traditional Pinyin IME (`com.apple.inputmethod.TCIM.Pinyin`) ranks as 太. This is the
    /// legitimate difference from the Zhuyin ㄊㄞˊ (tone 2) script, whose top candidates are
    /// 台/臺. All listed candidates are single Han ideographs, so the committed selection length
    /// stays one UTF-16 unit regardless of which candidate the IME picks.
    static let pinyin = ActualIMEScript(
        name: "Pinyin",
        compositionSteps: [
            ActualIMECompositionStep(key: .t, acceptableInsertedTexts: ["t"]),
            ActualIMECompositionStep(key: .a, acceptableInsertedTexts: ["ta"]),
            ActualIMECompositionStep(key: .i, acceptableInsertedTexts: ["tai"]),
        ],
        commitKeys: [.space, .returnKey, .returnKey],
        acceptableActiveCommitTexts: ["tai", "太", "台", "臺"],
        acceptableCommittedTexts: ["太", "台", "臺"]
    )
}

struct ActualIMECompositionStep {
    let key: ActualIMEKey
    let acceptableInsertedTexts: [String]
}

struct ActualIMEKey {
    let name: String
    let keyCode: CGKeyCode

    static let a = ActualIMEKey(name: "a", keyCode: 0)
    static let i = ActualIMEKey(name: "i", keyCode: 34)
    static let nine = ActualIMEKey(name: "9", keyCode: 25)
    static let returnKey = ActualIMEKey(name: "return", keyCode: 36)
    static let six = ActualIMEKey(name: "6", keyCode: 22)
    static let space = ActualIMEKey(name: "space", keyCode: 49)
    static let t = ActualIMEKey(name: "t", keyCode: 17)
    static let w = ActualIMEKey(name: "w", keyCode: 13)
}

struct ActualIMEFoldBoundaryScenario: CaseIterable {
    let name: String
    let source: String
    let insertionLocation: Int
    let foldedRanges: [NSRange]
    let developmentPresentation: MarkdownEditorDevelopmentPresentation
    let verifiesLinkFoldAfterCommit: Bool
    let imagePresentationState: ActualIMEImagePresentationState?

    init(
        name: String,
        source: String = actualIMEGateSource,
        insertionLocation: Int,
        foldedRanges: [NSRange],
        developmentPresentation: MarkdownEditorDevelopmentPresentation = .inlineFoldReveal,
        verifiesLinkFoldAfterCommit: Bool = false,
        imagePresentationState: ActualIMEImagePresentationState? = nil
    ) {
        self.name = name
        self.source = source
        self.insertionLocation = insertionLocation
        self.foldedRanges = foldedRanges
        self.developmentPresentation = developmentPresentation
        self.verifiesLinkFoldAfterCommit = verifiesLinkFoldAfterCommit
        self.imagePresentationState = imagePresentationState
    }

    static let allCases: [ActualIMEFoldBoundaryScenario] = {
        let source = actualIMEGateSource
        let headingMarker = (source as NSString).range(of: "# ")
        let boldSpan = (source as NSString).range(of: "**粗體**")
        let boldOpening = NSRange(location: boldSpan.location, length: 2)
        let boldClosing = NSRange(location: NSMaxRange(boldSpan) - 2, length: 2)
        let boldDelimiters = [boldOpening, boldClosing]
        let italicSpan = (source as NSString).range(of: "*斜體*")
        let italicOpening = NSRange(location: italicSpan.location, length: 1)
        let italicClosing = NSRange(location: NSMaxRange(italicSpan) - 1, length: 1)
        let italicDelimiters = [italicOpening, italicClosing]
        let inlineCodeSpan = (source as NSString).range(of: "`程式`")
        let inlineCodeOpening = NSRange(location: inlineCodeSpan.location, length: 1)
        let inlineCodeClosing = NSRange(location: NSMaxRange(inlineCodeSpan) - 1, length: 1)
        let inlineCodeDelimiters = [inlineCodeOpening, inlineCodeClosing]

        return [
            ActualIMEFoldBoundaryScenario(
                name: "heading after folded marker",
                insertionLocation: NSMaxRange(headingMarker),
                foldedRanges: [headingMarker]
            ),
            ActualIMEFoldBoundaryScenario(
                name: "bold before folded opening delimiter",
                insertionLocation: boldOpening.location,
                foldedRanges: boldDelimiters
            ),
            ActualIMEFoldBoundaryScenario(
                name: "bold after folded opening delimiter",
                insertionLocation: NSMaxRange(boldOpening),
                foldedRanges: boldDelimiters
            ),
            ActualIMEFoldBoundaryScenario(
                name: "bold before folded closing delimiter",
                insertionLocation: boldClosing.location,
                foldedRanges: boldDelimiters
            ),
            ActualIMEFoldBoundaryScenario(
                name: "bold after folded closing delimiter",
                insertionLocation: NSMaxRange(boldClosing),
                foldedRanges: boldDelimiters
            ),
            ActualIMEFoldBoundaryScenario(
                name: "italic before folded opening delimiter",
                insertionLocation: italicOpening.location,
                foldedRanges: italicDelimiters
            ),
            ActualIMEFoldBoundaryScenario(
                name: "italic after folded opening delimiter",
                insertionLocation: NSMaxRange(italicOpening),
                foldedRanges: italicDelimiters
            ),
            ActualIMEFoldBoundaryScenario(
                name: "italic before folded closing delimiter",
                insertionLocation: italicClosing.location,
                foldedRanges: italicDelimiters
            ),
            ActualIMEFoldBoundaryScenario(
                name: "italic after folded closing delimiter",
                insertionLocation: NSMaxRange(italicClosing),
                foldedRanges: italicDelimiters
            ),
            ActualIMEFoldBoundaryScenario(
                name: "inline code before folded opening delimiter",
                insertionLocation: inlineCodeOpening.location,
                foldedRanges: inlineCodeDelimiters
            ),
            ActualIMEFoldBoundaryScenario(
                name: "inline code after folded opening delimiter",
                insertionLocation: NSMaxRange(inlineCodeOpening),
                foldedRanges: inlineCodeDelimiters
            ),
            ActualIMEFoldBoundaryScenario(
                name: "inline code before folded closing delimiter",
                insertionLocation: inlineCodeClosing.location,
                foldedRanges: inlineCodeDelimiters
            ),
            ActualIMEFoldBoundaryScenario(
                name: "inline code after folded closing delimiter",
                insertionLocation: NSMaxRange(inlineCodeClosing),
                foldedRanges: inlineCodeDelimiters
            ),
        ]
    }()

    static let linkBoundaryCases: [ActualIMEFoldBoundaryScenario] = {
        let source = actualIMELinkGateSource
        let linkSpan = (source as NSString).range(of: "[連結文字](https://example.com/path)")
        let linkText = (source as NSString).range(of: "連結文字")
        let opening = NSRange(location: linkSpan.location, length: 1)
        let destination = NSRange(
            location: NSMaxRange(linkText),
            length: NSMaxRange(linkSpan) - NSMaxRange(linkText)
        )
        let foldedRanges = [opening, destination]

        return [
            ActualIMEFoldBoundaryScenario(
                name: "link at start of visible text",
                source: source,
                insertionLocation: linkText.location,
                foldedRanges: foldedRanges,
                developmentPresentation: .inlineFoldRevealWithLinkFolding,
                verifiesLinkFoldAfterCommit: true
            ),
            ActualIMEFoldBoundaryScenario(
                name: "link at destination edge after visible text",
                source: source,
                insertionLocation: NSMaxRange(linkText),
                foldedRanges: foldedRanges,
                developmentPresentation: .inlineFoldRevealWithLinkFolding,
                verifiesLinkFoldAfterCommit: true
            ),
            ActualIMEFoldBoundaryScenario(
                name: "link immediately after folded destination",
                source: source,
                insertionLocation: NSMaxRange(linkSpan),
                foldedRanges: foldedRanges,
                developmentPresentation: .inlineFoldRevealWithLinkFolding,
                verifiesLinkFoldAfterCommit: true
            ),
        ]
    }()

    static let imageBoundaryCases: [ActualIMEFoldBoundaryScenario] = {
        let source = actualIMEImageGateSource
        let imageSpan = (source as NSString).range(of: actualIMEImageGateLiteral)
        precondition(imageSpan.location != NSNotFound)

        return ActualIMEImagePresentationState.allCases.flatMap { state in
            [
                ActualIMEFoldBoundaryScenario(
                    name: "image immediately before \(state.scenarioName)",
                    source: source,
                    insertionLocation: imageSpan.location,
                    foldedRanges: [],
                    developmentPresentation: .inlineFoldRevealWithLinkFolding,
                    imagePresentationState: state
                ),
                ActualIMEFoldBoundaryScenario(
                    name: "image immediately after \(state.scenarioName)",
                    source: source,
                    insertionLocation: NSMaxRange(imageSpan),
                    foldedRanges: [],
                    developmentPresentation: .inlineFoldRevealWithLinkFolding,
                    imagePresentationState: state
                ),
            ]
        }
    }()
}

enum ActualIMEImagePresentationState: CaseIterable, Equatable {
    case readyThumbnail
    case loadingPlaceholder

    var scenarioName: String {
        switch self {
        case .readyThumbnail:
            "with ready thumbnail"
        case .loadingPlaceholder:
            "with loading placeholder"
        }
    }
}

struct ActualIMEInputSource {
    let source: TISInputSource
    let identifier: String
    let localizedName: String
    let inputSourceType: String

    var summary: String {
        "\(identifier) (\(localizedName)) [\(inputSourceType)]"
    }

    /// True only for composition-capable keyboard input methods/modes. Plain keyboard
    /// layouts (e.g. `com.apple.keylayout.PinyinKeyboard`) also match the CJK name filters
    /// but never produce marked text, so they must not be selected for the actual IME gate.
    var isComposingInputMethod: Bool {
        let composingTypes: Set<String> = [
            kTISTypeKeyboardInputMode as String,
            kTISTypeKeyboardInputMethodWithoutModes as String,
            kTISTypeKeyboardInputMethodModeEnabled as String,
        ]
        return composingTypes.contains(inputSourceType)
    }

    static func enabled(matching kind: Kind) -> ActualIMEInputSource? {
        inputSources(includeAllInstalled: false).first { kind.matches($0) && $0.isComposingInputMethod }
    }

    static func installed(matching kind: Kind) -> [ActualIMEInputSource] {
        inputSources(includeAllInstalled: true).filter { kind.matches($0) }
    }

    static func identifier(of source: TISInputSource) -> String? {
        propertyString(source, kTISPropertyInputSourceID)
    }

    private static func inputSources(includeAllInstalled: Bool) -> [ActualIMEInputSource] {
        let sources = TISCreateInputSourceList(nil, includeAllInstalled).takeRetainedValue() as NSArray
        return sources.map { item in
            // swiftlint:disable:next force_cast
            let source = item as! TISInputSource
            return ActualIMEInputSource(
                source: source,
                identifier: propertyString(source, kTISPropertyInputSourceID) ?? "<unknown>",
                localizedName: propertyString(source, kTISPropertyLocalizedName) ?? "<unknown>",
                inputSourceType: propertyString(source, kTISPropertyInputSourceType) ?? "<unknown>"
            )
        }
    }

    private static func propertyString(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else {
            return nil
        }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    enum Kind {
        case pinyin
        case zhuyin

        func matches(_ inputSource: ActualIMEInputSource) -> Bool {
            switch self {
            case .pinyin:
                inputSource.identifier.localizedCaseInsensitiveContains("pinyin")
                    || inputSource.identifier.localizedCaseInsensitiveContains("itabc")
                    || inputSource.localizedName.localizedCaseInsensitiveContains("pinyin")
                    || inputSource.localizedName.contains("拼音")
            case .zhuyin:
                inputSource.identifier.localizedCaseInsensitiveContains("zhuyin")
                    || inputSource.localizedName.localizedCaseInsensitiveContains("zhuyin")
                    || inputSource.localizedName.contains("注音")
            }
        }
    }
}

extension [String] {
    func containsInsertedText(in text: String, source: String, at insertionLocation: Int) -> Bool {
        insertedText(in: text, source: source, at: insertionLocation) != nil
    }

    func insertedText(in text: String, source: String, at insertionLocation: Int) -> String? {
        first { insertedText in
            source.insertingForActualIMEGate(insertedText, atUTF16Offset: insertionLocation) == text
        }
    }
}

extension String {
    func insertingForActualIMEGate(_ insertion: String, atUTF16Offset offset: Int) -> String {
        let index = String.Index(utf16Offset: offset, in: self)
        return String(self[..<index]) + insertion + String(self[index...])
    }
}
