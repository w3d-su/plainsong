import SwiftUI

/// Top-level app state: open workspaces, sessions, recents.
/// Populated from M1 (sessions) and M3 (workspaces) on — empty at M0.
@MainActor
final class AppState: ObservableObject {}
