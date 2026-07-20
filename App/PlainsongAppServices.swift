import Foundation

/// Process-wide App services that AppKit hooks can reach without casting `NSApp.delegate`.
///
/// SwiftUI's `@NSApplicationDelegateAdaptor` does not always expose the concrete
/// `PlainsongApplicationDelegate` as `NSApp.delegate` (live ⇧⌘F logging saw the cast fail
/// while the menu still worked). The SwiftUI app root assigns `appState` here on appear.
enum PlainsongAppServices {
    @MainActor
    static weak var appState: AppState?
}
