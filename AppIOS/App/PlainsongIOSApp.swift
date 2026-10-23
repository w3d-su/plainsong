import SwiftUI

@main
struct PlainsongIOSApp: App {
    private let composition = IOSProductionComposition.c0

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 16) {
                Text("Plainsong for iOS")
                    .font(.title)
                Text(composition.unavailableMessage)
                    .multilineTextAlignment(.center)
            }
            .padding()
        }
    }
}
