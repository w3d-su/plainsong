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
    /// Document-column width. The drag stops before the editor and preview fall through their floors.
    var availableWidth: CGFloat
    var contentMinimum: CGFloat
    @ViewBuilder let content: Content

    init(
        width: Binding<Double>,
        availableWidth: CGFloat,
        contentMinimum: CGFloat,
        @ViewBuilder content: () -> Content
    ) {
        _width = width
        self.availableWidth = availableWidth
        self.contentMinimum = contentMinimum
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 0) {
            InspectorResizeHandle(width: $width, availableWidth: availableWidth, contentMinimum: contentMinimum)
            content
                .frame(width: InspectorLayout.clamped(width))
                .frame(maxHeight: .infinity)
                .workspaceFrameProbe("inspector")
        }
    }
}

enum InspectorLayout {
    static let widthRange = 240.0 ... 360.0
    static let defaultWidth = 280.0
    static let handleWidth = 5.0

    static func clamped(_ width: Double) -> Double {
        min(max(width, widthRange.lowerBound), widthRange.upperBound)
    }

    /// Drag and VoiceOver stay inside 240...360 and inside the width that still fits the content floor.
    static func clamped(_ width: Double, availableWidth: CGFloat, contentMinimum: CGFloat) -> Double {
        let fitted = availableWidth - contentMinimum - handleWidth
        let upper = min(widthRange.upperBound, max(fitted, widthRange.lowerBound))
        return min(max(width, widthRange.lowerBound), upper)
    }
}

/// The column's leading edge: a hairline separator with a wider, invisible drag target.
private struct InspectorResizeHandle: View {
    @Binding var width: Double
    var availableWidth: CGFloat
    var contentMinimum: CGFloat
    @State private var widthAtDragStart: Double?
    @State private var isShowingResizeCursor = false

    var body: some View {
        let announced = Int(InspectorLayout.clamped(
            width, availableWidth: availableWidth, contentMinimum: contentMinimum
        ))
        return Rectangle()
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
                        width = InspectorLayout.clamped(
                            start - value.translation.width,
                            availableWidth: availableWidth,
                            contentMinimum: contentMinimum
                        )
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
            .workspaceFrameProbe("handle")
            .background(InspectorWidthAnnouncement(
                text: "\(announced) points",
                onIncrement: {
                    width = InspectorLayout.clamped(
                        width + 10, availableWidth: availableWidth, contentMinimum: contentMinimum
                    )
                },
                onDecrement: {
                    width = InspectorLayout.clamped(
                        width - 10, availableWidth: availableWidth, contentMinimum: contentMinimum
                    )
                }
            ))
    }
}

/// VoiceOver reads this view. SwiftUI's adjustable element exposes the actions but not the value.
private struct InspectorWidthAnnouncement: NSViewRepresentable {
    var text: String
    var onIncrement: () -> Void
    var onDecrement: () -> Void

    func makeNSView(context _: Context) -> AnnouncementView {
        AnnouncementView()
    }

    func updateNSView(_ view: AnnouncementView, context _: Context) {
        view.text = text
        view.onIncrement = onIncrement
        view.onDecrement = onDecrement
    }

    final class AnnouncementView: NSView {
        var text = ""
        var onIncrement: (() -> Void)?
        var onDecrement: (() -> Void)?
        override func hitTest(_: NSPoint) -> NSView? {
            nil
        }

        override func isAccessibilityElement() -> Bool {
            true
        }

        override func accessibilityLabel() -> String? {
            "Inspector width"
        }

        override func accessibilityValue() -> Any? {
            text
        }

        override func accessibilityPerformIncrement() -> Bool {
            onIncrement?()
            return true
        }

        override func accessibilityPerformDecrement() -> Bool {
            onDecrement?()
            return true
        }
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
    @Published private(set) var userIntent: Bool
    @Published private(set) var isPresented = false
    @Published private(set) var hasDocument = false
    private weak var window: NSWindow?
    private var keyObservation: KeyWindowObservation?
    private var availableWidth: CGFloat = 0
    private var requiredWidth: CGFloat = 0
    /// Latest geometry. Updated without publishing so Show sees the current column during a view update.
    private var recordedHasDocument = false

    init(userIntent: Bool) {
        self.userIntent = userIntent
    }

    /// Stores the column measurement. Does not publish; call `applyRecordedLayout` to update visibility.
    func recordLayout(availableWidth: CGFloat, inspectorWidth: Double, contentMinimum: CGFloat, hasDocument: Bool) {
        self.availableWidth = availableWidth
        requiredWidth = contentMinimum + InspectorLayout.clamped(inspectorWidth) + InspectorLayout.handleWidth
        recordedHasDocument = hasDocument
    }

    func applyRecordedLayout() {
        if hasDocument != recordedHasDocument { hasDocument = recordedHasDocument }
        refreshVisibility()
    }

    func updateLayout(availableWidth: CGFloat, inspectorWidth: Double, contentMinimum: CGFloat, hasDocument: Bool) {
        recordLayout(
            availableWidth: availableWidth,
            inspectorWidth: inspectorWidth,
            contentMinimum: contentMinimum,
            hasDocument: hasDocument
        )
        applyRecordedLayout()
    }

    func setUserIntent(_ intent: Bool) {
        if userIntent != intent { userIntent = intent }
        refreshVisibility()
    }

    func toggle() {
        guard recordedHasDocument else { return }
        let show = !isPresented
        setUserIntent(show)
        guard show, requiredWidth > availableWidth, let window else { return }
        // A full-screen window cannot grow. Keep the Show intent and stay collapsed.
        if window.styleMask.contains(.fullScreen) { return }
        guard let screen = window.screen else { return }
        let deficit = requiredWidth - availableWidth
        let visible = screen.visibleFrame
        var frame = window.frame
        frame.size.width = min(frame.width + deficit, visible.width)
        frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
        window.setFrame(frame, display: true)
        // The geometry callback decides visibility after the screen-clamped resize.
    }

    private func refreshVisibility() {
        let visible = userIntent && recordedHasDocument && availableWidth >= requiredWidth
        if isPresented != visible { isPresented = visible }
    }

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
        if window.isKeyWindow { InspectorMenuState.shared.windowBecameKey(self) }
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
        visibilitySubscription = visibility.$isPresented.combineLatest(visibility.$hasDocument)
            .sink { [weak self] isPresented, hasDocument in
                self?.isKeyWindowInspectorPresented = hasDocument ? isPresented : nil
            }
    }

    func windowResignedKey(_ visibility: InspectorVisibility) {
        guard keyWindowVisibility === visibility else { return }
        keyWindowVisibility = nil
        visibilitySubscription = nil
        isKeyWindowInspectorPresented = nil
    }

    func toggleKeyWindowInspector() {
        keyWindowVisibility?.toggle()
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
                MainActor.assumeIsolated { onChange(true) }
            },
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { onChange(false) }
            },
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { onChange(false) }
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
