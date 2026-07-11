/// Literal source-text equality without Unicode normalization.
///
/// Swift `String` equality treats canonically equivalent Unicode as equal. Editor source
/// state instead needs the exact UTF-16 code-unit sequence so byte-different input still
/// propagates through versioning, dirty tracking, and App bindings. This comparison walks
/// the existing string views directly and does not allocate or hash the document.
public enum ExactSourceText {
    public static func matches(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf16.elementsEqual(rhs.utf16)
    }
}
