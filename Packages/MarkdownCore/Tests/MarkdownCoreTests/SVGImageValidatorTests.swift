import Foundation
import MarkdownCore
import XCTest

final class SVGImageValidatorTests: XCTestCase {
    func testAdmitsFragmentReferencesAndSafeAnimation() {
        assertAdmission([
            SVGAdmissionCase("minimal", #"<svg xmlns="http://www.w3.org/2000/svg"/>"#, .admit),
            SVGAdmissionCase(
                "fragment use",
                """
                <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink">
                  <defs><g id="mark"><rect width="1" height="1"/></g></defs>
                  <use xlink:href="#mark" href="#mark"/>
                </svg>
                """,
                .admit
            ),
            SVGAdmissionCase(
                "style fragment and animation of a length",
                """
                <svg xmlns="http://www.w3.org/2000/svg">
                  <style><![CDATA[rect { fill: url(#paint); }]]></style>
                  <rect style="fill:url(#paint)" width="1" height="1">
                    <animate attributeName="width" from="1" to="2" dur="1s"/>
                  </rect>
                </svg>
                """,
                .admit
            ),
            SVGAdmissionCase(
                "quoted fragment",
                #"<svg xmlns="http://www.w3.org/2000/svg"><rect fill="url( '#paint' )"/></svg>"#,
                .admit
            ),
        ])
    }

    func testRejectsMalformedRootsDoctypesAndEntityBombs() {
        assertAdmission([
            SVGAdmissionCase("empty", "", .reject(.malformed)),
            SVGAdmissionCase(
                "not svg",
                #"<html xmlns="http://www.w3.org/1999/xhtml"></html>"#,
                .reject(.rootIsNotSVG)
            ),
            SVGAdmissionCase("missing namespace", "<svg></svg>", .reject(.rootIsNotSVG)),
            SVGAdmissionCase(
                "foreign namespace",
                #"<svg xmlns="http://example.com/svg"></svg>"#,
                .reject(.rootIsNotSVG)
            ),
            SVGAdmissionCase(
                "doctype",
                #"<!DOCTYPE svg><svg xmlns="http://www.w3.org/2000/svg"/>"#,
                .reject(.doctype)
            ),
            SVGAdmissionCase(
                "lowercase doctype",
                #"<!doctype svg><svg xmlns="http://www.w3.org/2000/svg"/>"#,
                .reject(.doctype)
            ),
            SVGAdmissionCase(
                "entity bomb",
                """
                <!DOCTYPE lolz [<!ENTITY lol "lol"><!ENTITY lol2 "&lol;&lol;&lol;&lol;">]>
                <svg xmlns="http://www.w3.org/2000/svg">&lol2;</svg>
                """,
                .reject(.doctype)
            ),
            SVGAdmissionCase("truncated", #"<svg xmlns="http://www.w3.org/2000/svg">"#, .reject(.malformed)),
        ])
    }

    func testRejectsScriptForeignContentHandlersAndProcessingInstructions() {
        assertAdmission([
            SVGAdmissionCase(
                "script",
                #"<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>"#,
                .reject(.forbiddenElement("script"))
            ),
            SVGAdmissionCase(
                "script case",
                #"<svg xmlns="http://www.w3.org/2000/svg"><SCRIPT/></svg>"#,
                .reject(.forbiddenElement("script"))
            ),
            SVGAdmissionCase(
                "foreignObject",
                #"<svg xmlns="http://www.w3.org/2000/svg"><foreignObject/></svg>"#,
                .reject(.forbiddenElement("foreignobject"))
            ),
            SVGAdmissionCase(
                "iframe",
                #"<svg xmlns="http://www.w3.org/2000/svg"><iframe/></svg>"#,
                .reject(.forbiddenElement("iframe"))
            ),
            SVGAdmissionCase(
                "object",
                #"<svg xmlns="http://www.w3.org/2000/svg"><object/></svg>"#,
                .reject(.forbiddenElement("object"))
            ),
            SVGAdmissionCase(
                "embed",
                #"<svg xmlns="http://www.w3.org/2000/svg"><embed/></svg>"#,
                .reject(.forbiddenElement("embed"))
            ),
            SVGAdmissionCase(
                "handler",
                #"<svg xmlns="http://www.w3.org/2000/svg"><handler/></svg>"#,
                .reject(.forbiddenElement("handler"))
            ),
            SVGAdmissionCase(
                "listener",
                #"<svg xmlns="http://www.w3.org/2000/svg"><listener/></svg>"#,
                .reject(.forbiddenElement("listener"))
            ),
            SVGAdmissionCase(
                "onload",
                #"<svg xmlns="http://www.w3.org/2000/svg" onload="alert(1)"/>"#,
                .reject(.eventHandlerAttribute("onload"))
            ),
            SVGAdmissionCase(
                "onclick case",
                #"<svg xmlns="http://www.w3.org/2000/svg"><g ONCLICK="alert(1)"/></svg>"#,
                .reject(.eventHandlerAttribute("onclick"))
            ),
            SVGAdmissionCase(
                "smil set",
                """
                <svg xmlns="http://www.w3.org/2000/svg">\
                <set attributeName="href" to="https://example.invalid"/></svg>
                """,
                .reject(.smilHrefTarget)
            ),
            SVGAdmissionCase(
                "smil xlink",
                """
                <svg xmlns="http://www.w3.org/2000/svg">\
                <animate attributeName="xlink:href" values="#a;https://example.invalid"/></svg>
                """,
                .reject(.smilHrefTarget)
            ),
            SVGAdmissionCase(
                "stylesheet pi",
                #"<?xml-stylesheet href="https://example.invalid/a.css"?><svg xmlns="http://www.w3.org/2000/svg"/>"#,
                .reject(.processingInstruction("xml-stylesheet"))
            ),
        ])
    }

    func testRejectsExternalReferencesAndStyleLoads() {
        assertAdmission([
            SVGAdmissionCase(
                "https href",
                #"<svg xmlns="http://www.w3.org/2000/svg"><image href="https://example.invalid/a.png"/></svg>"#,
                .reject(.externalReference("href"))
            ),
            SVGAdmissionCase(
                "http href",
                #"<svg xmlns="http://www.w3.org/2000/svg"><a href="http://example.invalid"/></svg>"#,
                .reject(.externalReference("href"))
            ),
            SVGAdmissionCase(
                "file href",
                #"<svg xmlns="http://www.w3.org/2000/svg"><use href="file:///tmp/a.svg"/></svg>"#,
                .reject(.externalReference("href"))
            ),
            SVGAdmissionCase(
                "relative href",
                #"<svg xmlns="http://www.w3.org/2000/svg"><use href="other.svg#icon"/></svg>"#,
                .reject(.externalReference("href"))
            ),
            SVGAdmissionCase(
                "empty href",
                #"<svg xmlns="http://www.w3.org/2000/svg"><use href=""/></svg>"#,
                .reject(.externalReference("href"))
            ),
            SVGAdmissionCase(
                "javascript href",
                #"<svg xmlns="http://www.w3.org/2000/svg"><a href="javascript:alert(1)"/></svg>"#,
                .reject(.externalReference("href"))
            ),
            SVGAdmissionCase(
                "xlink https",
                """
                <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink">\
                <use xlink:href="https://example.invalid/a.svg"/></svg>
                """,
                .reject(.externalReference("href"))
            ),
            SVGAdmissionCase(
                "src",
                #"<svg xmlns="http://www.w3.org/2000/svg"><image src="https://example.invalid/a.png"/></svg>"#,
                .reject(.externalReference("src"))
            ),
            SVGAdmissionCase(
                "import",
                """
                <svg xmlns="http://www.w3.org/2000/svg">\
                <style>@import url(https://example.invalid/a.css);</style></svg>
                """,
                .reject(.externalStyle)
            ),
            SVGAdmissionCase(
                "style url",
                """
                <svg xmlns="http://www.w3.org/2000/svg">\
                <rect style="fill:url(https://example.invalid/a.png)"/></svg>
                """,
                .reject(.externalStyle)
            ),
            SVGAdmissionCase(
                "style data url",
                """
                <svg xmlns="http://www.w3.org/2000/svg">\
                <rect style="fill:url(data:image/png;base64,AA)"/></svg>
                """,
                .reject(.externalStyle)
            ),
            SVGAdmissionCase(
                "fill url",
                """
                <svg xmlns="http://www.w3.org/2000/svg">\
                <rect fill="url(https://example.invalid/a.png)"/></svg>
                """,
                .reject(.externalStyle)
            ),
        ])
    }

    func testRejectsNonUTF8AndTheByteCapAtItsBoundary() {
        let utf16 = "<svg/>".data(using: .utf16)!
        XCTAssertEqual(SVGImageValidator.admission(of: utf16), .reject(.invalidEncoding))

        let tooLarge = Data(count: SVGImageValidator.maximumByteCount + 1)
        XCTAssertEqual(
            SVGImageValidator.admission(of: tooLarge),
            .reject(.tooLarge(
                byteCount: SVGImageValidator.maximumByteCount + 1,
                maximumByteCount: SVGImageValidator.maximumByteCount
            ))
        )

        var atCap = Data(#"<svg xmlns="http://www.w3.org/2000/svg"/>"#.utf8)
        atCap.append(Data(count: SVGImageValidator.maximumByteCount - atCap.count))
        XCTAssertEqual(atCap.count, SVGImageValidator.maximumByteCount)
        XCTAssertEqual(SVGImageValidator.admission(of: atCap), .reject(.malformed))

        let prefix = Data(#"<?xml version="1.0" encoding="UTF-8"?><svg xmlns="http://www.w3.org/2000/svg"><!--"#.utf8)
        let suffix = Data("--></svg>".utf8)
        let padding = SVGImageValidator.maximumByteCount - prefix.count - suffix.count
        XCTAssertGreaterThan(padding, 0)
        var exact = prefix
        exact.append(Data(repeating: 0x20, count: padding))
        exact.append(suffix)
        XCTAssertEqual(exact.count, SVGImageValidator.maximumByteCount)
        XCTAssertEqual(SVGImageValidator.admission(of: exact), .admit)
    }

    func testElementAndDepthCapsAdmitTheBoundaryAndRejectOnePastIt() {
        XCTAssertEqual(admission(elements: SVGImageValidator.maximumElementCount), .admit)
        XCTAssertEqual(
            admission(elements: SVGImageValidator.maximumElementCount + 1),
            .reject(.tooManyElements(SVGImageValidator.maximumElementCount + 1))
        )
        XCTAssertEqual(admission(depth: SVGImageValidator.maximumDepth), .admit)
        XCTAssertEqual(
            admission(depth: SVGImageValidator.maximumDepth + 1),
            .reject(.tooDeep(SVGImageValidator.maximumDepth + 1))
        )
    }

    func testExporterFixturesAreAdmittedUnchanged() throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/SVG", isDirectory: true)
        for name in ["inkscape-1.3-export.svg", "figma-export.svg", "illustrator-export.svg"] {
            let url = directory.appendingPathComponent(name)
            let data = try Data(contentsOf: url)
            XCTAssertEqual(SVGImageValidator.admission(of: data), .admit, name)
            XCTAssertEqual(try Data(contentsOf: url), data, "admission must not rewrite \(name)")
        }
    }

    private func assertAdmission(_ cases: [SVGAdmissionCase], file: StaticString = #filePath, line: UInt = #line) {
        for item in cases {
            XCTAssertEqual(
                SVGImageValidator.admission(of: Data(item.xml.utf8)),
                item.expected,
                item.name,
                file: file,
                line: line
            )
        }
    }

    private func admission(elements: Int) -> SVGImageAdmission {
        var xml = #"<svg xmlns="http://www.w3.org/2000/svg">"#
        for _ in 1 ..< elements {
            xml += "<g/>"
        }
        xml += "</svg>"
        return SVGImageValidator.admission(of: Data(xml.utf8))
    }

    private func admission(depth: Int) -> SVGImageAdmission {
        let nested = max(0, depth - 1)
        let xml = #"<svg xmlns="http://www.w3.org/2000/svg">"#
            + String(repeating: "<g>", count: nested)
            + String(repeating: "</g>", count: nested)
            + "</svg>"
        return SVGImageValidator.admission(of: Data(xml.utf8))
    }
}

private struct SVGAdmissionCase {
    let name: String
    let xml: String
    let expected: SVGImageAdmission

    init(_ name: String, _ xml: String, _ expected: SVGImageAdmission) {
        self.name = name
        self.xml = xml
        self.expected = expected
    }
}
