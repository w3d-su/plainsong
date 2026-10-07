import AppKit
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

/// The key window's inspector visibility, for View › Show/Hide Inspector.
struct InspectorVisibilityKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

extension FocusedValues {
    var inspectorVisibility: Binding<Bool>? {
        get { self[InspectorVisibilityKey.self] }
        set { self[InspectorVisibilityKey.self] = newValue }
    }
}

/// View › Show/Hide Inspector (⌃⌘I) for the key workspace window.
struct InspectorToggleCommands: Commands {
    @FocusedBinding(\.inspectorVisibility) private var isInspectorPresented

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button(isInspectorPresented == true ? "Hide Inspector" : "Show Inspector") {
                isInspectorPresented?.toggle()
            }
            .keyboardShortcut("i", modifiers: [.control, .command])
            .disabled(isInspectorPresented == nil)
        }
    }
}
