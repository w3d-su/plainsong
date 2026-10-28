import Foundation

/// Accept or reject a user SVG before preview serves it as an image.
/// The bytes are never rewritten: callers serve the original data or nothing.
public enum SVGImageAdmission: Equatable, Sendable {
    case admit
    case reject(SVGImageRejection)
}

public enum SVGImageRejection: Equatable, Sendable {
    case tooLarge(byteCount: Int, maximumByteCount: Int)
    case invalidEncoding
    case doctype
    case malformed
    case rootIsNotSVG
    case forbiddenElement(String)
    case eventHandlerAttribute(String)
    case externalReference(String)
    case externalStyle
    case smilHrefTarget
    case processingInstruction(String)
    case tooManyElements(Int)
    case tooDeep(Int)
}

public enum SVGImageValidator {
    public static let maximumByteCount = 1_048_576
    public static let maximumElementCount = 50000
    public static let maximumDepth = 256
    public static let mimeType = "image/svg+xml"
    public static let contentSecurityPolicy = "default-src 'none'; style-src 'unsafe-inline'"
    public static let namespace = "http://www.w3.org/2000/svg"

    /// Structural check only. `data` is not mutated and is not returned.
    public static func admission(of data: Data) -> SVGImageAdmission {
        guard data.count <= maximumByteCount else {
            return .reject(.tooLarge(byteCount: data.count, maximumByteCount: maximumByteCount))
        }
        guard let source = String(data: data, encoding: .utf8) else {
            return .reject(.invalidEncoding)
        }
        if let prologIssue = prologIssue(in: source) {
            return .reject(prologIssue)
        }

        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.allowedExternalEntityURLs = []
        let probe = SVGDocumentProbe()
        parser.delegate = probe
        let parsed = parser.parse()
        if let rejection = probe.rejection {
            return .reject(rejection)
        }
        guard parsed, probe.sawRoot else {
            return .reject(.malformed)
        }
        return .admit
    }

    fileprivate static let forbiddenElements: Set<String> = [
        "embed", "foreignobject", "handler", "iframe", "listener", "object", "script",
    ]
    fileprivate static let smilElements: Set<String> = [
        "animate", "animatecolor", "animatemotion", "animatetransform", "set",
    ]
    /// Presentation attributes that take CSS image values. `url(#id)` stays allowed.
    private static let cssValuedAttributes: Set<String> = [
        "clip-path", "cursor", "fill", "filter", "marker-end", "marker-mid",
        "marker-start", "mask", "stroke", "style",
    ]

    fileprivate static func localName(of key: String) -> String {
        if let brace = key.lastIndex(of: "}") {
            return String(key[key.index(after: brace)...])
        }
        if let colon = key.lastIndex(of: ":") {
            return String(key[key.index(after: colon)...])
        }
        return key
    }

    fileprivate static func attributeRejection(_ attributes: [String: String]) -> SVGImageRejection? {
        for (key, value) in attributes {
            let name = localName(of: key).lowercased()
            if isEventHandler(name) {
                return .eventHandlerAttribute(name)
            }
            if name == "href" || name == "src", !isSameDocumentFragment(value) {
                return .externalReference(name)
            }
            if cssValuedAttributes.contains(name), cssContainsDisallowedReference(value) {
                return .externalStyle
            }
        }
        return nil
    }

    fileprivate static func targetsHref(_ attributes: [String: String]) -> Bool {
        for (key, value) in attributes {
            guard localName(of: key).lowercased() == "attributename" else { continue }
            let target = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if target == "href" || target == "src" || target.hasSuffix(":href") {
                return true
            }
        }
        return false
    }

    fileprivate static func cssContainsDisallowedReference(_ css: String) -> Bool {
        let text = css.lowercased()
        if text.contains("@import") {
            return true
        }
        var remainder = text[...]
        while let range = remainder.range(of: "url(") {
            let after = range.upperBound
            guard let close = remainder[after...].firstIndex(of: ")") else { return true }
            let raw = remainder[after ..< close].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let reference = unquotedCSSReference(raw), isFragmentToken(reference) else {
                return true
            }
            remainder = remainder[remainder.index(after: close)...]
        }
        return false
    }

    private static func isEventHandler(_ name: String) -> Bool {
        guard name.count > 2, name.hasPrefix("on") else { return false }
        let third = name[name.index(name.startIndex, offsetBy: 2)]
        return third.isLetter
    }

    private static func isSameDocumentFragment(_ value: String) -> Bool {
        isFragmentToken(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func isFragmentToken(_ value: some StringProtocol) -> Bool {
        guard value.count >= 2, value.first == "#" else { return false }
        return value.dropFirst().allSatisfy { character in
            character != "#" && character != "(" && character != ")" && character != "\\" &&
                character != "/" && character != ":" && character != "\"" && character != "'" &&
                !character.isWhitespace
        }
    }

    private static func unquotedCSSReference(_ raw: String) -> String? {
        guard let first = raw.first, first == "\"" || first == "'" else {
            if raw.contains("\"") || raw.contains("'") { return nil }
            return String(raw)
        }
        guard raw.last == first, raw.count >= 2 else { return nil }
        return String(raw.dropFirst().dropLast().trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// DOCTYPE is rejected before `XMLParser` runs, so an internal subset is never expanded.
    private static func prologIssue(in source: String) -> SVGImageRejection? {
        var index = source.startIndex
        if source.hasPrefix("\u{FEFF}") {
            index = source.index(after: index)
        }
        var sawElement = false
        var allowsXMLDeclaration = true
        while index < source.endIndex {
            while index < source.endIndex, source[index].isWhitespace {
                index = source.index(after: index)
            }
            guard index < source.endIndex else { break }
            guard hasPrefix(source, from: index, "<") else { return .malformed }
            if hasPrefix(source, from: index, "<?") {
                guard let end = endOfProcessingInstruction(source, from: index) else { return .malformed }
                let target = processingInstructionTarget(source, from: index)
                if target != "xml" || !allowsXMLDeclaration {
                    return .processingInstruction(target)
                }
                allowsXMLDeclaration = false
                index = end
                continue
            }
            allowsXMLDeclaration = false
            if hasPrefix(source, from: index, "<!--") {
                guard let end = source.range(of: "-->", range: source.index(index, offsetBy: 4) ..< source.endIndex)?
                    .upperBound
                else { return .malformed }
                index = end
                continue
            }
            if hasPrefix(source, from: index, "<!doctype") {
                return .doctype
            }
            if hasPrefix(source, from: index, "<!") {
                return .malformed
            }
            sawElement = true
            break
        }
        return sawElement ? nil : .malformed
    }

    private static func hasPrefix(_ source: String, from index: String.Index, _ prefix: String) -> Bool {
        guard let end = source.index(index, offsetBy: prefix.count, limitedBy: source.endIndex) else {
            return false
        }
        return source[index ..< end].lowercased() == prefix
    }

    private static func processingInstructionTarget(_ source: String, from index: String.Index) -> String {
        var cursor = source.index(index, offsetBy: 2)
        let start = cursor
        while cursor < source.endIndex {
            let character = source[cursor]
            if character.isWhitespace || character == "?" { break }
            cursor = source.index(after: cursor)
        }
        return source[start ..< cursor].lowercased()
    }

    private static func endOfProcessingInstruction(_ source: String, from index: String.Index) -> String.Index? {
        source.range(of: "?>", range: source.index(index, offsetBy: 2) ..< source.endIndex)?.upperBound
    }
}

private final class SVGDocumentProbe: NSObject, XMLParserDelegate {
    private(set) var rejection: SVGImageRejection?
    private(set) var sawRoot = false
    private var elementCount = 0
    private var depth = 0
    private var styleDepth = 0
    private var styleText = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName _: String?,
        attributes: [String: String] = [:]
    ) {
        guard rejection == nil else { return }
        elementCount += 1
        if elementCount > SVGImageValidator.maximumElementCount {
            reject(.tooManyElements(elementCount), parser: parser)
            return
        }
        depth += 1
        if depth > SVGImageValidator.maximumDepth {
            reject(.tooDeep(depth), parser: parser)
            return
        }
        let name = elementName.lowercased()
        if !sawRoot {
            sawRoot = true
            if name != "svg" || namespaceURI != SVGImageValidator.namespace {
                reject(.rootIsNotSVG, parser: parser)
                return
            }
        }
        if SVGImageValidator.forbiddenElements.contains(name) {
            reject(.forbiddenElement(name), parser: parser)
            return
        }
        if SVGImageValidator.smilElements.contains(name), SVGImageValidator.targetsHref(attributes) {
            reject(.smilHrefTarget, parser: parser)
            return
        }
        if let attributeRejection = SVGImageValidator.attributeRejection(attributes) {
            reject(attributeRejection, parser: parser)
            return
        }
        if name == "style" {
            styleDepth += 1
            styleText = ""
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?
    ) {
        guard rejection == nil else { return }
        if elementName.lowercased() == "style", styleDepth > 0 {
            if SVGImageValidator.cssContainsDisallowedReference(styleText) {
                reject(.externalStyle, parser: parser)
                return
            }
            styleDepth -= 1
            styleText = ""
        }
        depth = max(0, depth - 1)
    }

    func parser(_: XMLParser, foundCharacters string: String) {
        if styleDepth > 0 { styleText += string }
    }

    func parser(_ parser: XMLParser, foundCDATA block: Data) {
        guard styleDepth > 0 else { return }
        guard let text = String(data: block, encoding: .utf8) else {
            reject(.invalidEncoding, parser: parser)
            return
        }
        styleText += text
    }

    func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data _: String?) {
        reject(.processingInstruction(target.lowercased()), parser: parser)
    }

    func parser(_: XMLParser, resolveExternalEntityName _: String, systemID _: String?) -> Data? {
        rejection = rejection ?? .doctype
        return nil
    }

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName _: String, value _: String?) {
        reject(.doctype, parser: parser)
    }

    func parser(
        _ parser: XMLParser,
        foundExternalEntityDeclarationWithName _: String,
        publicID _: String?,
        systemID _: String?
    ) {
        reject(.doctype, parser: parser)
    }

    func parser(_ parser: XMLParser, foundElementDeclarationWithName _: String, model _: String) {
        reject(.doctype, parser: parser)
    }

    func parser(
        _ parser: XMLParser,
        foundAttributeDeclarationWithName _: String,
        forElement _: String,
        type _: String?,
        defaultValue _: String?
    ) {
        reject(.doctype, parser: parser)
    }

    func parser(
        _ parser: XMLParser,
        foundUnparsedEntityDeclarationWithName _: String,
        publicID _: String?,
        systemID _: String?,
        notationName _: String?
    ) {
        reject(.doctype, parser: parser)
    }

    func parser(
        _ parser: XMLParser,
        foundNotationDeclarationWithName _: String,
        publicID _: String?,
        systemID _: String?
    ) {
        reject(.doctype, parser: parser)
    }

    private func reject(_ reason: SVGImageRejection, parser: XMLParser) {
        guard rejection == nil else { return }
        rejection = reason
        parser.abortParsing()
    }
}
