import AppKit
import Combine
import SwiftUI

/// Trailing inspector column inside the document column: a separator the user drags to
/// resize, then the inspector content.
///
/// Not SwiftUI's `.inspector`. With `.inspector` mounted — on the detail column or the split
/// view, even with static content — the editor's SwiftUI updates intermittently stalled in
/// the hosted Find/Replace gates: published navigations and selection-driven WYSIWYG reveals
/// never reached the editor (`docs/decision-log.md`, window chrome PR L).
struct InspectorColumn<Content: View>: View {
    @Binding var width: Double
    @ViewBuilder let content: Content

    init(width: Binding<Double>, @ViewBuilder content: () -> Content) {
        _width = width
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 0) {
            InspectorResizeHandle(width: $width)
            content
                .frame(width: InspectorLayout.clamped(width))
                .frame(maxHeight: .infinity)
        }
    }
}

enum InspectorLayout {
    static let widthRange = 240.0 ... 360.0
    static let defaultWidth = 280.0

    static func clamped(_ width: Double) -> Double {
        min(max(width, widthRange.lowerBound), widthRange.upperBound)
    }
}

/// The column's leading edge: a hairline separator with a wider, invisible drag target.
private struct InspectorResizeHandle: View {
    @Binding var width: Double
    @State private var widthAtDragStart: Double?
    @State private var isShowingResizeCursor = false

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .padding(.horizontal, 2)
            .contentShape(Rectangle())
            .onHover { isInside in
                guard isInside != isShowingResizeCursor else { return }
                isShowingResizeCursor = isInside
                if isInside {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = widthAtDragStart ?? InspectorLayout.clamped(width)
                        widthAtDragStart = start
                        width = InspectorLayout.clamped(start - value.translation.width)
                    }
                    .onEnded { _ in
                        widthAtDragStart = nil
                    }
            )
            .onDisappear {
                if isShowingResizeCursor {
                    isShowingResizeCursor = false
                    NSCursor.pop()
                }
            }
            .accessibilityHidden(true)
    }
}

/// One window's inspector visibility.
///
/// View › Show/Hide Inspector reaches it through `InspectorMenuState`, not a SwiftUI focused
/// value: with any focused value or focused object published by the workspace window, the
/// editor's own SwiftUI updates were delayed in the hosted Find/Replace gates (decision log,
/// window chrome PR L).
@MainActor
final class InspectorVisibility: ObservableObject {
    @Published var isPresented = true
    private weak var window: NSWindow?
    private var keyObservation: KeyWindowObservation?

    /// Follows `window`'s key status so the menu acts on the key window's inspector only.
    func attach(to window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        keyObservation = KeyWindowObservation(window: window) { [weak self] isKey in
            guard let self else { return }
            if isKey {
                InspectorMenuState.shared.windowBecameKey(self)
            } else {
                InspectorMenuState.shared.windowResignedKey(self)
            }
        }
        if window.isKeyWindow {
            InspectorMenuState.shared.windowBecameKey(self)
        }
    }
}

/// The key workspace window's inspector, for the app-global View menu.
@MainActor
final class InspectorMenuState: ObservableObject {
    static let shared = InspectorMenuState()

    /// `nil` while no workspace window is key (Settings, a panel), so the command disables
    /// instead of falling back to another window.
    @Published private(set) var isKeyWindowInspectorPresented: Bool?
    private weak var keyWindowVisibility: InspectorVisibility?
    private var visibilitySubscription: AnyCancellable?

    func windowBecameKey(_ visibility: InspectorVisibility) {
        keyWindowVisibility = visibility
        visibilitySubscription = visibility.$isPresented.sink { [weak self] isPresented in
            self?.isKeyWindowInspectorPresented = isPresented
        }
    }

    func windowResignedKey(_ visibility: InspectorVisibility) {
        guard keyWindowVisibility === visibility else { return }
        keyWindowVisibility = nil
        visibilitySubscription = nil
        isKeyWindowInspectorPresented = nil
    }

    func toggleKeyWindowInspector() {
        keyWindowVisibility?.isPresented.toggle()
    }
}

/// Become/resign-key observers for one window, removed when this is released.
private final class KeyWindowObservation {
    private var tokens: [NSObjectProtocol] = []

    @MainActor
    init(window: NSWindow, onChange: @escaping @MainActor (Bool) -> Void) {
        let center = NotificationCenter.default
        tokens = [
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { _ in
                Task { @MainActor in onChange(true) }
            },
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { _ in
                Task { @MainActor in onChange(false) }
            },
        ]
    }

    deinit {
        tokens.forEach(NotificationCenter.default.removeObserver)
    }
}

/// View › Show/Hide Inspector (⌃⌘I) for the key workspace window.
///
/// The app owns `menuState` and passes it in, like `MenuBarState` for `PlainsongCommands`; a
/// state object created inside `Commands` left the item's launch-time enablement frozen.
struct InspectorToggleCommands: Commands {
    @ObservedObject var menuState: InspectorMenuState

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button(menuState.isKeyWindowInspectorPresented == true ? "Hide Inspector" : "Show Inspector") {
                menuState.toggleKeyWindowInspector()
            }
            .keyboardShortcut("i", modifiers: [.control, .command])
            .disabled(menuState.isKeyWindowInspectorPresented == nil)
        }
    }
}
