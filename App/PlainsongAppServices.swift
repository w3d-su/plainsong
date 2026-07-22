import Foundation

/// Process-wide App services that the Carbon hot-key callback can reach.
///
/// The SwiftUI app root assigns `appState` during initialization, before the app-active
/// `Command-Shift-F` registration can deliver a callback.
enum PlainsongAppServices {
    @MainActor
    weak static var appState: AppState?
}
