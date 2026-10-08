import Foundation

/// UTF-8 only. A value that does not round-trip to the same bytes is refused so open
/// cannot strip a BOM or replace bytes and then treat the document as clean.
enum IOSDocumentTextCodec {
    static func decode(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        guard Data(text.utf8) == data else { return nil }
        return text
    }

    static func encode(_ text: String) -> Data {
        Data(text.utf8)
    }
}
