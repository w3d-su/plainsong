@testable import MarkdownCore
import XCTest

final class CustomThemeValidationTests: XCTestCase {
    func testAcceptsEveryEditorAndPreviewKeyAndInheritsMissingSlots() throws {
        let editor = Dictionary(uniqueKeysWithValues: CustomThemeDocument.editorColorKeys.enumerated()
            .map { index, key in
                (key, String(format: "#%02X%02X%02X", index, index + 1, index + 2))
            })
        let preview = Dictionary(uniqueKeysWithValues: CustomThemeDocument.previewColorKeys.enumerated()
            .map { index, key in
                (key, String(format: "#%02X%02X%02XAA", index, 20 + index, 40))
            })
        let document = try validate([
            "schemaVersion": 1,
            "id": "solarized-ink",
            "name": "Solarized Ink",
            "light": ["editor": editor, "preview": preview],
            "dark": ["editor": ["text": "#AABBCC"]],
        ])

        XCTAssertEqual(document.id, "solarized-ink")
        XCTAssertEqual(document.name, "Solarized Ink")
        XCTAssertEqual(document.light.editor, editor)
        XCTAssertEqual(document.light.preview, preview)
        XCTAssertEqual(document.dark?.editor, ["text": "#AABBCC"])
        XCTAssertEqual(document.dark?.preview, [:])
    }

    func testMissingKeysAndOmittedDarkInherit() throws {
        let document = try validate([
            "schemaVersion": 1,
            "id": "ink",
            "name": "Ink",
            "light": ["editor": ["heading": "#0B4F9C"]],
        ])

        XCTAssertEqual(document.light.editor, ["heading": "#0B4F9C"])
        XCTAssertNil(document.light.editor["text"])
        XCTAssertNil(document.light.editor["gutter"])
        XCTAssertTrue(document.light.preview.isEmpty)
        XCTAssertNil(document.dark)
    }

    func testAcceptsEightDigitAndLowercaseColors() throws {
        let document = try validate([
            "schemaVersion": 1,
            "id": "a",
            "name": "A",
            "light": ["editor": ["caret": "#aabbccdd", "selection": "#AABBCC"]],
        ])
        XCTAssertEqual(document.light.editor["caret"], "#aabbccdd")
        XCTAssertEqual(document.light.editor["selection"], "#AABBCC")
    }

    func testAcceptsExactly64KiBAndRejectsOneByteOver() throws {
        let minimal = Data("{\"schemaVersion\":1,\"id\":\"ink\",\"name\":\"Ink\",\"light\":{}}".utf8)
        let exact = minimal + Data(repeating: 0x20, count: CustomThemeDocument.maximumByteCount - minimal.count)
        XCTAssertEqual(exact.count, CustomThemeDocument.maximumByteCount)
        XCTAssertEqual(try CustomThemeValidation.validate(exact).get().id, "ink")

        let oversized = exact + Data([0x20])
        XCTAssertEqual(
            CustomThemeValidation.validate(oversized),
            .failure(.exceedsMaximumSize(byteCount: CustomThemeDocument.maximumByteCount + 1))
        )
    }

    func testRejectionsCoverTheClosedSchema() throws {
        for sample in schemaRejections() + colorRejections() {
            let data = try rejectionData(sample.payload)
            XCTAssertEqual(CustomThemeValidation.validate(data), .failure(sample.expected), sample.label)
        }
    }

    private func schemaRejections() -> [Rejection] {
        [
            Rejection(label: "invalid utf-8", payload: Data([0xFF, 0xFE]), expected: .invalidUTF8),
            Rejection(label: "broken json", payload: Data("{".utf8), expected: .invalidJSON),
            Rejection(label: "array", payload: [1], expected: .invalidJSON),
            Rejection(
                label: "bool schema",
                payload: ["schemaVersion": true, "id": "ink", "name": "Ink", "light": [:]],
                expected: .invalidJSON
            ),
            Rejection(
                label: "fractional schema",
                payload: ["schemaVersion": 1.5, "id": "ink", "name": "Ink", "light": [:]],
                expected: .invalidJSON
            ),
            Rejection(label: "schema 0", payload: base(schema: 0), expected: .unsupportedSchemaVersion(0)),
            Rejection(label: "schema 2", payload: base(schema: 2), expected: .unsupportedSchemaVersion(2)),
            Rejection(
                label: "missing schema",
                payload: ["id": "ink", "name": "Ink", "light": [:]],
                expected: .missingField("schemaVersion")
            ),
            Rejection(
                label: "missing id",
                payload: ["schemaVersion": 1, "name": "Ink", "light": [:]],
                expected: .missingField("id")
            ),
            Rejection(
                label: "missing name",
                payload: ["schemaVersion": 1, "id": "ink", "light": [:]],
                expected: .missingField("name")
            ),
            Rejection(
                label: "missing light",
                payload: ["schemaVersion": 1, "id": "ink", "name": "Ink"],
                expected: .missingField("light")
            ),
            Rejection(label: "null dark", payload: base(extra: ["dark": NSNull()]), expected: .invalidJSON),
            Rejection(label: "uppercase id", payload: base(id: "Ink"), expected: .identifier),
            Rejection(label: "underscore id", payload: base(id: "ink_1"), expected: .identifier),
            Rejection(label: "empty id", payload: base(id: ""), expected: .identifier),
            Rejection(
                label: "long id",
                payload: base(id: String(repeating: "a", count: 65)),
                expected: .identifier
            ),
        ]
    }

    private func colorRejections() -> [Rejection] {
        [
            Rejection(
                label: "standard id",
                payload: base(id: "standard"),
                expected: .reservedIdentifier("standard")
            ),
            Rejection(
                label: "graphite id",
                payload: base(id: "graphite"),
                expected: .reservedIdentifier("graphite")
            ),
            Rejection(label: "empty name", payload: base(name: ""), expected: .name),
            Rejection(
                label: "long name",
                payload: base(name: String(repeating: "N", count: 65)),
                expected: .name
            ),
            Rejection(
                label: "short color",
                payload: base(editor: ["text": "#FFF"]),
                expected: .color("light.editor.text")
            ),
            Rejection(
                label: "named color",
                payload: base(editor: ["text": "red"]),
                expected: .color("light.editor.text")
            ),
            Rejection(
                label: "css color",
                payload: base(editor: ["background": "rgb(0,0,0)"]),
                expected: .color("light.editor.background")
            ),
            Rejection(
                label: "null color",
                payload: base(editor: ["caret": NSNull()]),
                expected: .color("light.editor.caret")
            ),
            Rejection(
                label: "font field",
                payload: base(editor: ["font": "#112233"]),
                expected: .unknownField("light.editor.font")
            ),
            Rejection(
                label: "top-level css",
                payload: base(extra: ["css": "body{}"]),
                expected: .unknownField("css")
            ),
            Rejection(
                label: "preview url",
                payload: base(preview: ["url": "#112233"]),
                expected: .unknownField("light.preview.url")
            ),
            Rejection(
                label: "palette extra",
                payload: base(light: ["editor": [:], "extra": [:]]),
                expected: .unknownField("light.extra")
            ),
        ]
    }

    private func rejectionData(_ payload: Any) throws -> Data {
        if let existing = payload as? Data {
            return existing
        }
        return try json(payload)
    }

    func testHyphenatedIdentifierAndMaximumNameAreAccepted() throws {
        let document = try validate(base(id: "-ok-", name: String(repeating: "n", count: 64)))
        XCTAssertEqual(document.id, "-ok-")
        XCTAssertEqual(document.name.count, 64)
    }

    private func validate(_ payload: Any) throws -> CustomThemeDocument {
        try CustomThemeValidation.validate(json(payload)).get()
    }

    private func base(
        schema: Int = 1,
        id: String = "ink",
        name: String = "Ink",
        editor: [String: Any]? = nil,
        preview: [String: Any]? = nil,
        light: [String: Any]? = nil,
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        var root: [String: Any] = [
            "schemaVersion": schema,
            "id": id,
            "name": name,
            "light": light ?? {
                var palette: [String: Any] = [:]
                if let editor { palette["editor"] = editor }
                if let preview { palette["preview"] = preview }
                return palette
            }(),
        ]
        for (key, value) in extra {
            root[key] = value
        }
        return root
    }

    private func json(_ payload: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: payload)
    }
}

private struct Rejection {
    var label: String
    var payload: Any
    var expected: CustomThemeValidationFailure
}
