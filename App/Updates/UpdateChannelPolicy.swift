import Foundation

/// Sparkle channel set for Settings › General › Receive beta updates.
/// An empty set is the default channel only; `beta` is opt-in.
enum UpdateChannelPolicy {
    static func allowedChannels(receivesBetaUpdates: Bool) -> Set<String> {
        receivesBetaUpdates ? ["beta"] : []
    }
}
