import Foundation

/// Literal source-text equality without Unicode normalization.
///
/// Swift `String` equality treats canonically equivalent Unicode as equal. Editor source
/// state instead needs the exact UTF-16 code-unit sequence so byte-different input still
/// propagates through versioning, dirty tracking, and App bindings. Foundation's literal
/// comparison keeps that contract while using its optimized contiguous-string path for the
/// editor's 1 MiB no-op and persisted-baseline checks.
public enum ExactSourceText {
    public static func matches(_ lhs: String, _ rhs: String) -> Bool {
        (lhs as NSString).compare(rhs, options: .literal) == .orderedSame
    }
}
