import Foundation

/// Whether a window may open a file or workspace root. Production extra scenes refuse until
/// PR D2; hosted fixtures opt in. Stored off `WindowState` so the §3.2 property inventory
/// stays the B1 set (`docs/window-state-gates.md` §10 row C).
///
/// Fails closed: a window with no live decision refuses. Each entry holds its window weakly,
/// so a reused object address never inherits a released window's decision.
@MainActor
enum WindowOpenAdmission {
    private struct Decision {
        weak var window: WindowState?
        let admits: Bool
    }

    #if DEBUG
        /// Hosted fixtures set this so a later production scene may open files. Release builds
        /// do not have it.
        static var testingBypass = false
    #endif

    /// Whether a scene after the first is admitted. Always false outside DEBUG fixtures.
    static var admitsLaterScenes: Bool {
        #if DEBUG
            testingBypass
        #else
            false
        #endif
    }

    private static var decisions: [ObjectIdentifier: Decision] = [:]

    static func set(_ window: WindowState, admits: Bool) {
        decisions = decisions.filter { $0.value.window != nil }
        decisions[ObjectIdentifier(window)] = Decision(window: window, admits: admits)
    }

    static func admits(_ window: WindowState) -> Bool {
        guard let decision = decisions[ObjectIdentifier(window)], decision.window === window else {
            return false
        }
        return decision.admits
    }

    static func forget(_ window: WindowState) {
        decisions[ObjectIdentifier(window)] = nil
    }

    #if DEBUG
        static func resetForTesting() {
            testingBypass = false
            decisions = decisions.filter { $0.value.window != nil }
        }
    #endif
}
