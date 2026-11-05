import Foundation

/// Whether a window may open a file or workspace root. Since PR D2 every production scene is
/// admitted; a façade built with `admitsFileOperations: false` still refuses every open,
/// restore, and New File. Stored off `WindowState` so the §3.2 property inventory stays the
/// B1 set (`docs/window-state-gates.md` §10 row C).
///
/// Fails closed: a window with no live decision refuses. Each entry holds its window weakly,
/// so a reused object address never inherits a released window's decision.
@MainActor
enum WindowOpenAdmission {
    private struct Decision {
        weak var window: WindowState?
        let admits: Bool
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
            decisions = decisions.filter { $0.value.window != nil }
        }
    #endif
}
