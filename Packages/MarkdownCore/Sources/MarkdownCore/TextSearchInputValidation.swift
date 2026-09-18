/// Shared single-line policy for literal Find queries and replacement values.
enum TextSearchInputValidation {
    static func containsNewline(_ text: String) -> Bool {
        text.contains(where: \.isNewline)
    }
}
