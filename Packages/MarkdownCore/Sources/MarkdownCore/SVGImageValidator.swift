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
    /// The charset pins WebKit to UTF-8 (RFC 7303: the HTTP charset overrides the XML
    /// declaration), so it decodes the same characters the validator parsed.
    public static let mimeType = "image/svg+xml; charset=utf-8"
    /// Backstop for document mode only. WebKit builds an SVG image from the bytes and is
    /// not expected to apply response headers in image mode; navigation and the page CSP
    /// already keep `asset://` SVG out of document mode.
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

    /// SMIL value attributes. An animation can set `fill` or `style` to `url(https:…)`.
    private static let smilValueAttributes: Set<String> = ["by", "from", "to", "values"]

    fileprivate static func attributeRejection(
        _ attributes: [String: String],
        isSMIL: Bool
    ) -> SVGImageRejection? {
        for (key, value) in attributes {
            let name = localName(of: key).lowercased()
            if isEventHandler(name) {
                return .eventHandlerAttribute(name)
            }
            if name == "href" || name == "src", !isSameDocumentFragment(value) {
                return .externalReference(name)
            }
            let carriesCSS = cssValuedAttributes.contains(name) || (isSMIL && smilValueAttributes.contains(name))
            if carriesCSS, cssContainsDisallowedReference(value) {
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

    private static func isEventHandler(_ name: String) -> Bool {
        guard name.count > 2, name.hasPrefix("on") else { return false }
        let third = name[name.index(name.startIndex, offsetBy: 2)]
        return third.isLetter
    }

    private static func isSameDocumentFragment(_ value: String) -> Bool {
        isFragmentToken(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func isFragmentToken(_ value: some StringProtocol) -> Bool {
        guard value.count >= 2, value.first == "#" else { return false }
        return value.dropFirst().allSatisfy { character in
            character != "#" && character != "(" && character != ")" && character != "\\" &&
                character != "/" && character != ":" && character != "\"" && character != "'" &&
                !character.isWhitespace
        }
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
                switch xmlDeclaration(in: source, from: index, allowed: allowsXMLDeclaration) {
                case let .reject(rejection): return rejection
                case let .end(end): index = end
                }
                allowsXMLDeclaration = false
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

    /// Only a leading `<?xml …?>` declaring UTF-8 (or nothing) is allowed. XMLParser decodes
    /// by the declared encoding and WebKit by the response charset; UTF-8 keeps both on the
    /// bytes already checked as UTF-8.
    private static func xmlDeclaration(
        in source: String,
        from index: String.Index,
        allowed: Bool
    ) -> XMLDeclarationScan {
        guard let end = endOfProcessingInstruction(source, from: index) else { return .reject(.malformed) }
        let target = processingInstructionTarget(source, from: index)
        guard target == "xml", allowed else { return .reject(.processingInstruction(target)) }
        if let encoding = declaredEncoding(in: source[index ..< end]), encoding != "utf-8" {
            return .reject(.invalidEncoding)
        }
        return .end(end)
    }

    private enum XMLDeclarationScan {
        case end(String.Index)
        case reject(SVGImageRejection)
    }

    /// The `encoding` pseudo-attribute of an XML declaration, lowercased, or nil when absent.
    static func declaredEncoding(in declaration: Substring) -> String? {
        let lowered = declaration.lowercased()
        guard let name = lowered.range(of: "encoding") else { return nil }
        var rest = lowered[name.upperBound...].drop(while: \.isWhitespace)
        guard rest.first == "=" else { return "" }
        rest = rest.dropFirst().drop(while: \.isWhitespace)
        guard let quote = rest.first, quote == "\"" || quote == "'" else { return "" }
        let value = rest.dropFirst().prefix { $0 != quote }
        return String(value)
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
    private var inStyle = false
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
        if !sawRoot {
            sawRoot = true
            // XML names are case-sensitive: `<SVG>` is not the SVG root.
            if elementName != "svg" || namespaceURI != SVGImageValidator.namespace {
                reject(.rootIsNotSVG, parser: parser)
                return
            }
        }
        let name = elementName.lowercased()
        // `<style>` holds text only. A child element (a nested `<style>` included) would
        // split its CSS into pieces the end-of-element check never sees together.
        if inStyle {
            reject(.externalStyle, parser: parser)
            return
        }
        if SVGImageValidator.forbiddenElements.contains(name) {
            reject(.forbiddenElement(name), parser: parser)
            return
        }
        let isSMIL = SVGImageValidator.smilElements.contains(name)
        if isSMIL, SVGImageValidator.targetsHref(attributes) {
            reject(.smilHrefTarget, parser: parser)
            return
        }
        if let attributeRejection = SVGImageValidator.attributeRejection(attributes, isSMIL: isSMIL) {
            reject(attributeRejection, parser: parser)
            return
        }
        if name == "style" {
            inStyle = true
            styleText = ""
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement _: String,
        namespaceURI _: String?,
        qualifiedName _: String?
    ) {
        guard rejection == nil else { return }
        if inStyle {
            if SVGImageValidator.cssContainsDisallowedReference(styleText) {
                reject(.externalStyle, parser: parser)
                return
            }
            inStyle = false
            styleText = ""
        }
        depth = max(0, depth - 1)
    }

    func parser(_: XMLParser, foundCharacters string: String) {
        if inStyle { styleText += string }
    }

    func parser(_ parser: XMLParser, foundCDATA block: Data) {
        guard inStyle else { return }
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
