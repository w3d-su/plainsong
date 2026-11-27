import UIKit
import XCTest

@MainActor
func makeHostedTestWindow(width: CGFloat = 390, height: CGFloat = 844) throws -> UIWindow {
    let scene = try XCTUnwrap(
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first {
            $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive
        },
        "Hosted window tests require a foreground UIWindowScene"
    )
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: width, height: height)
    return window
}
