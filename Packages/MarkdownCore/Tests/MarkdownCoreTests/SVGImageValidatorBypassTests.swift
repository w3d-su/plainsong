import Foundation
import MarkdownCore
import XCTest

/// PR #229 review: inputs that reached WebKit with a different meaning than the
/// validator saw (nested style, CSS escapes, SMIL values, declared encodings).
final class SVGImageValidatorBypassTests: XCTestCase {
    private static let open = #"<svg xmlns="http://www.w3.org/2000/svg">"#

    func testNestedStyleAndStyleChildrenAreRejected() {
        assertRejected(.externalStyle, [
            "nested style": "<style>@import url(https://x.invalid/a.css); <style/></style>",
            "nested style after text": "<style>rect{fill:url(https://x.invalid/a)}<style>a{}</style></style>",
            "element in style": "<style><g/></style>",
        ])
        XCTAssertEqual(admission(body: "<style>rect{fill:url(#a)}</style><style>g{}</style>"), .admit)
    }

    func testCSSEscapesAndResourceFunctionsAreRejected() {
        assertRejected(.externalStyle, [
            "escaped url": #"<style>rect{fill:u\72l(https://x.invalid/a)}</style>"#,
            "escaped url with space": #"<style>rect{fill:u\72 l(https://x.invalid/a)}</style>"#,
            "escaped import": #"<style>@\69mport "https://x.invalid/a.css";</style>"#,
            "escaped letter": #"<style>@i\mport "https://x.invalid/a.css";</style>"#,
            "image-set": #"<style>rect{fill:image-set("https://x.invalid/a.png" 1x)}</style>"#,
            "webkit image-set": #"<style>rect{fill:-webkit-image-set("https://x.invalid/a.png" 1x)}</style>"#,
            "cross-fade": #"<style>rect{fill:cross-fade("https://x.invalid/a.png", red 50%)}</style>"#,
            "style attribute import": #"<rect style="@import 'https://x.invalid/a.css'"/>"#,
            "style attribute escape": #"<rect style="fill:\75 rl(https://x.invalid/a)"/>"#,
        ])
    }

    func testEscapedFontNamesAndFragmentsStayAdmitted() {
        // Illustrator writes CJK font families as CSS escapes.
        XCTAssertEqual(
            admission(body: #"<text style="font-family:'\5FAE\8F6F\96C5\9ED1'">x</text>"#),
            .admit
        )
        XCTAssertEqual(admission(body: #"<style>.a{font-family:"\5B8B\4F53";fill:url(#g)}</style>"#), .admit)
    }

    func testSMILValueAttributesAreScannedAsCSS() {
        assertRejected(.externalStyle, [
            "values": #"<rect><animate attributeName="fill" values="red;url(https://x.invalid/a)"/></rect>"#,
            "set to": #"<rect><set attributeName="fill" to="url(https://x.invalid/a)"/></rect>"#,
            "from": #"<rect><animate attributeName="style" from="fill:url(https://x.invalid/a)"/></rect>"#,
            "by": #"<rect><animate attributeName="stroke" by="url(https://x.invalid/a)"/></rect>"#,
        ])
        let fragments = #"<animate attributeName="fill" from="url(#a)" to="url(#b)" values="url(#a);url(#b)"/>"#
        XCTAssertEqual(admission(body: "<rect>\(fragments)</rect>"), .admit)
        XCTAssertEqual(admission(body: #"<rect><animate attributeName="opacity" values="0;1"/></rect>"#), .admit)
    }

    func testDeclaredEncodingMustBeUTF8() {
        for encoding in ["ISO-8859-1", "Shift_JIS", "UTF-7", "UTF-16", "utf8"] {
            let xml = #"<?xml version="1.0" encoding="\#(encoding)"?>"# + Self.open + "</svg>"
            XCTAssertEqual(SVGImageValidator.admission(of: Data(xml.utf8)), .reject(.invalidEncoding), encoding)
        }
        let malformed = #"<?xml version="1.0" encoding=utf-8?>"# + Self.open + "</svg>"
        XCTAssertEqual(SVGImageValidator.admission(of: Data(malformed.utf8)), .reject(.invalidEncoding))
        for declaration in [
            #"<?xml version="1.0" encoding="utf-8"?>"#,
            #"<?xml version='1.0' encoding = 'UTF-8' ?>"#,
            #"<?xml version="1.0"?>"#,
        ] {
            let xml = declaration + Self.open + "</svg>"
            XCTAssertEqual(SVGImageValidator.admission(of: Data(xml.utf8)), .admit, declaration)
        }
    }

    func testInvalidUTF8IsRejected() {
        var data = Data(Self.open.utf8)
        data.append(contentsOf: [0xC3, 0x28])
        data.append(Data("</svg>".utf8))
        XCTAssertEqual(SVGImageValidator.admission(of: data), .reject(.invalidEncoding))
    }

    func testDoctypeAfterBOMDeclarationOrCommentIsRejected() {
        let svg = Self.open + "</svg>"
        for prefix in [
            "\u{FEFF}<!DOCTYPE svg>",
            #"<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE svg>"#,
            "<!-- exported --><!DOCTYPE svg>",
            "\u{FEFF}<?xml version=\"1.0\"?>\n<!-- c -->\n<!doctype svg>",
        ] {
            XCTAssertEqual(SVGImageValidator.admission(of: Data((prefix + svg).utf8)), .reject(.doctype), prefix)
        }
    }

    func testExternalAndParameterEntitiesAreRejected() {
        for doctype in [
            #"<!DOCTYPE svg [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>"#,
            #"<!DOCTYPE svg [<!ENTITY % p SYSTEM "file:///etc/passwd"> %p;]>"#,
            #"<!DOCTYPE svg SYSTEM "file:///etc/passwd">"#,
        ] {
            let xml = doctype + Self.open + "</svg>"
            XCTAssertEqual(SVGImageValidator.admission(of: Data(xml.utf8)), .reject(.doctype), doctype)
        }
    }

    func testBodyProcessingInstructionAndUppercaseRootAreRejected() {
        XCTAssertEqual(admission(body: "<?foo bar?>"), .reject(.processingInstruction("foo")))
        XCTAssertEqual(
            SVGImageValidator.admission(of: Data(#"<SVG xmlns="http://www.w3.org/2000/svg"></SVG>"#.utf8)),
            .reject(.rootIsNotSVG)
        )
    }

    func testServedMIMETypeCarriesUTF8Charset() {
        XCTAssertEqual(SVGImageValidator.mimeType, "image/svg+xml; charset=utf-8")
    }

    private func admission(body: String) -> SVGImageAdmission {
        SVGImageValidator.admission(of: Data((Self.open + body + "</svg>").utf8))
    }

    private func assertRejected(
        _ rejection: SVGImageRejection,
        _ cases: [String: String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for (name, body) in cases.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(admission(body: body), .reject(rejection), name, file: file, line: line)
        }
    }
}
