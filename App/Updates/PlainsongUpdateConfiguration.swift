import Foundation

/// `PLAINSONG_UPDATES_ENABLED` from the built Info.plist.
/// Missing or unrecognized values stay disabled, so a packaging mistake cannot
/// turn updates on.
enum PlainsongUpdateConfiguration {
    static let enabledKey = "PLAINSONG_UPDATES_ENABLED"

    static func isEnabled(in bundle: Bundle) -> Bool {
        isEnabled(infoValue: bundle.object(forInfoDictionaryKey: enabledKey))
    }

    static func isEnabled(infoValue: Any?) -> Bool {
        switch infoValue {
        case let value as Bool:
            value
        case let value as String:
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "yes", "true", "1":
                true
            default:
                false
            }
        case let value as NSNumber:
            value.boolValue
        default:
            false
        }
    }
}
