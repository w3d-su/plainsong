import Foundation

public enum SmartPaste {
    public static func isSingleURL(_ candidate: String) -> Bool {
        guard !candidate.isEmpty,
              candidate.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let url = URL(string: candidate),
              let scheme = url.scheme,
              !scheme.isEmpty
        else {
            return false
        }

        if scheme == "http" || scheme == "https" {
            return url.host?.isEmpty == false
        }
        return candidate.contains(":")
    }

    public static func linkReplacement(selection: String, url: String) -> String? {
        guard !selection.isEmpty, isSingleURL(url) else { return nil }
        return "[\(selection)](\(url))"
    }

    public static func imageInsertion(relativePath: String) -> String {
        "![](\(relativePath))"
    }
}
