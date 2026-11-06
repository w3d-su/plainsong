import UIKit

/// Editor fonts the source view can actually construct. A missing family falls
/// back to the system monospaced face instead of failing the setting.
public enum IOSEditorFont {
    public static let system = "System Monospaced"

    private static let candidates: [(title: String, names: [String])] = [
        (system, []),
        ("Menlo", ["Menlo", "Menlo-Regular"]),
        ("Courier New", ["Courier New", "CourierNewPSMT"]),
        ("SF Mono", ["SF Mono", "SFMono-Regular"]),
    ]

    public static func availableTitles() -> [String] {
        candidates.compactMap { candidate in
            if candidate.title == system { return candidate.title }
            return candidate.names.contains { UIFont(name: $0, size: 13) != nil } ? candidate.title : nil
        }
    }

    public static func resolved(_ title: String) -> String {
        let available = availableTitles()
        return available.contains(title) ? title : system
    }

    public static func isSystem(_ title: String) -> Bool {
        title.isEmpty || title == system
    }

    public static func font(named title: String, size: CGFloat) -> UIFont {
        if isSystem(title) {
            return UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
        let names = candidates.first { $0.title == title }?.names ?? [title]
        for name in names {
            if let font = UIFont(name: name, size: size) {
                return font
            }
        }
        return UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}
