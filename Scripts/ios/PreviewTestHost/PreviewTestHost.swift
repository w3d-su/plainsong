import SwiftUI

/// Provides UIApplication and a scene for WebKit XCTest without loading app packages twice.
@main
struct PreviewTestHost: App {
    var body: some Scene {
        WindowGroup {
            Text("Plainsong preview tests")
        }
    }
}
