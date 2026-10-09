import AppKit
@testable import Plainsong
import SwiftUI
import WebKit
import XCTest

@MainActor
extension EditorFindHostedGateTests {
    func testNativeLayoutFixedShellWidthIntentMatrix() async throws {
        try await checkWidthIntentMatrix(shell: .fixed)
    }

    func testNativeLayoutSplitShellWidthIntentMatrix() async throws {
        guard #available(macOS 27.0, *) else { throw XCTSkip("Split shell is gated to macOS 27+") }
        try await checkWidthIntentMatrix(shell: .split)
    }

    func testSplitShellChromeMatchesTheRecordedConstant() async throws {
        guard #available(macOS 27.0, *) else { throw XCTSkip("Split shell is gated to macOS 27+") }
        let fixture = try makeWorkspaceFixture(files: ["post.md": "# Layout\n"])
        let state = fixture.appState
        state.openExternalFile(fixture.root)
        try await waitUntil("chrome fixture opens") { state.currentDocument.fileURL != nil }
        state.setLayoutMode(.sourcePreview)
        let setting = NativeInspectorIntent(true)
        let host = makeNativeLayoutHost(appState: state, shell: .split, setting: setting)
        registerTeardown(host: host, fixture: fixture)
        host.window.setContentSize(NSSize(width: 1400, height: 680))
        try await waitUntil("split chrome frames settle") {
            host.hostingView.layoutSubtreeIfNeeded()
            return self.layoutFrame("sidebar", in: host.window) != nil
                && self.layoutFrame("document", in: host.window) != nil
        }
        let content = host.hostingView.bounds.width
        let sidebar = try XCTUnwrap(layoutFrame("sidebar", in: host.window))
        let document = try XCTUnwrap(layoutFrame("document", in: host.window))
        let chrome = content - sidebar.width - document.width
        print(
            "SPLIT_CHROME content=\(content) sidebar=\(sidebar.width) minX=\(sidebar.minX) " +
                "document=\(document.width) maxX=\(document.maxX) chrome=\(chrome)"
        )
        XCTAssertEqual(sidebar.width, 320, accuracy: 0.5)
        XCTAssertEqual(chrome, WorkspaceLayout.splitShellChrome, accuracy: 0.5,
                       "Record this measured chrome in WorkspaceLayout.splitShellChrome")
    }

    func testTooWideInspectorIncrementStaysVisibleAtTheClampedWidth() async throws {
        let fixture = try makeWorkspaceFixture(files: ["post.md": "# Layout\n"])
        let state = fixture.appState
        state.openExternalFile(fixture.root)
        try await waitUntil("clamp fixture opens") { state.currentDocument.fileURL != nil }
        state.setLayoutMode(.sourceOnly)
        let setting = NativeInspectorIntent(true)
        let host = makeNativeLayoutHost(appState: state, shell: .fixed, setting: setting)
        registerTeardown(host: host, fixture: fixture)
        let floor = WorkspaceLayout.fixedShellWindowMinimum
        try await waitUntil("fixed floor installed") { host.window.contentMinSize.width == floor }
        // 864 pt source-only fits an inspector, but not the 360 pt maximum.
        host.window.setContentSize(NSSize(width: 864, height: 680))
        try await waitUntil("inspector visible before the increment") {
            host.hostingView.layoutSubtreeIfNeeded()
            return self.layoutFrame("inspector", in: host.window) != nil
        }
        let document = try XCTUnwrap(layoutFrame("document", in: host.window))
        let fitted = InspectorLayout.clamped(
            360, availableWidth: document.width, contentMinimum: WorkspaceLayout.editorMinimum
        )
        let handle = try XCTUnwrap(
            AccessibilityQuery.find(identifier: nil, label: "Inspector width", in: host.window),
            AccessibilityQuery.summary(in: host.window)
        )
        for _ in 0 ..< 12 {
            XCTAssertTrue(AccessibilityQuery.performIncrement(on: handle))
            host.hostingView.layoutSubtreeIfNeeded()
        }
        try await waitUntil("clamped increment keeps the inspector") {
            host.hostingView.layoutSubtreeIfNeeded()
            guard let inspector = self.layoutFrame("inspector", in: host.window) else { return false }
            return abs(inspector.width - fitted) <= 1
        }
        let inspector = try XCTUnwrap(layoutFrame("inspector", in: host.window))
        XCTAssertEqual(inspector.width, fitted, accuracy: 1)
        XCTAssertEqual(setting.width, fitted, accuracy: 1, "Persisted width must be the clamped width")
        let announcedHandle = try XCTUnwrap(
            AccessibilityQuery.find(identifier: nil, label: "Inspector width", in: host.window),
            AccessibilityQuery.summary(in: host.window)
        )
        XCTAssertEqual(
            AccessibilityQuery.value(of: announcedHandle),
            "\(Int(InspectorLayout.clamped(fitted))) points"
        )
        XCTAssertLessThanOrEqual(
            WorkspaceLayout.editorMinimum + inspector.width + InspectorLayout.handleWidth,
            document.width + 1
        )
    }

    func testDirtyDocumentFileNameValueStaysTheFileName() async throws {
        let fixture = try makeWorkspaceFixture(files: ["post.md": "# Layout\n"])
        let state = fixture.appState
        state.openExternalFile(fixture.root)
        try await waitUntil("file name fixture opens") { state.currentDocument.fileURL != nil }
        let host = makeNativeLayoutHost(appState: state, shell: .fixed, setting: NativeInspectorIntent(false))
        registerTeardown(host: host, fixture: fixture)
        state.currentDocument.replaceText(state.currentDocument.text + "\nedited\n", refreshStatistics: false)
        try await waitUntil("window exposes the edited state") {
            state.currentDocument.isDirty && host.window.isDocumentEdited
        }
        let element = try XCTUnwrap(
            AccessibilityQuery.find(identifier: "plainsong.editor.fileName", label: nil, in: host.window),
            AccessibilityQuery.summary(in: host.window)
        )
        XCTAssertEqual(AccessibilityQuery.value(of: element), "post.md")
        XCTAssertTrue(host.window.isDocumentEdited)
    }

    private func checkWidthIntentMatrix(shell: WorkspaceShell) async throws {
        let requests = widthRequests(shell: shell)
        let floor = WorkspaceLayout.windowMinimum(splitShell: shell == .split)
        for layout in [EditorLayoutMode.sourceOnly, .sourcePreview, .wysiwyg] {
            for intent in [true, false] {
                let fixture = try makeWorkspaceFixture(files: ["post.md": "# Layout\n\n**hello**"])
                let state = fixture.appState
                state.preferences.setExperimentalWYSIWYGEnabled(true)
                state.openExternalFile(fixture.root)
                try await waitUntil("layout fixture opens") { state.currentDocument.fileURL != nil }
                state.setLayoutMode(layout)
                let setting = NativeInspectorIntent(intent)
                let host = makeNativeLayoutHost(appState: state, shell: shell, setting: setting)
                registerTeardown(host: host, fixture: fixture)
                var inspectorColumnWidth: CGFloat?
                for requested in requests {
                    // setContentSize bypasses AppKit's interactive resize constraint; model the
                    // user's resize with the production window's actual contentMinSize.
                    try await waitUntil("window minimum installed") {
                        host.window.contentMinSize.width == floor
                    }
                    host.window.setContentSize(NSSize(
                        width: max(requested, host.window.contentMinSize.width),
                        height: 680
                    ))
                    try await waitUntil("layout settles at requested \(requested)") {
                        host.hostingView.layoutSubtreeIfNeeded()
                        guard let editor = self.layoutFrame("editor", in: host.window),
                              let document = self.layoutFrame("document", in: host.window) else { return false }
                        let required = WorkspaceLayout.contentMinimum(preview: state.isPreviewVisible)
                            + InspectorLayout.defaultWidth + InspectorLayout.handleWidth
                        let expectedInspector = intent && document.width + 0.5 >= required
                        guard (self.layoutFrame("inspector", in: host.window) != nil) == expectedInspector
                        else { return false }
                        let trailing = self.layoutFrame("inspector", in: host.window)
                            ?? self.layoutFrame("preview", in: host.window) ?? editor
                        return editor.width >= WorkspaceLayout.editorMinimum - 0.5
                            && abs(trailing.maxX - host.hostingView.bounds.width) <= 0.5
                    }
                    // Sizes below the constant floor are clamped by the actual production root.
                    XCTAssertGreaterThanOrEqual(host.hostingView.bounds.width, floor - 0.5)
                    try await assertNativeLayout(in: host.window, preview: state.isPreviewVisible)
                    let sidebar = try XCTUnwrap(layoutFrame("sidebar", in: host.window))
                    XCTAssertEqual(sidebar.width, shell == .fixed ? 256 : 320, accuracy: 0.5)
                    XCTAssertEqual(setting.value, intent, "Automatic collapse must never persist itself")
                    if shell == .fixed, requested == 780, state.isPreviewVisible {
                        XCTAssertNil(layoutFrame("inspector", in: host.window),
                                     "780 pt Split must auto-collapse the inspector")
                    }
                    if requested == 1280 {
                        try await waitUntil("inspector restored iff requested") {
                            (self.layoutFrame("inspector", in: host.window) != nil) == intent
                        }
                        if intent {
                            let handle = try XCTUnwrap(layoutFrame("handle", in: host.window))
                            let inspector = try XCTUnwrap(layoutFrame("inspector", in: host.window))
                            inspectorColumnWidth = inspector.maxX - handle.minX
                        }
                    } else if state.isPreviewVisible {
                        try await waitUntil("narrow Split auto-collapses") {
                            self.layoutFrame("inspector", in: host.window) == nil
                        }
                    }
                }
                if intent {
                    host.window.makeKeyAndOrderFront(nil)
                    print(
                        "INSPECTOR_MODEL document=\(setting.visibility.hasDocument)",
                        "visible=\(setting.visibility.isPresented)",
                        "intent=\(setting.visibility.userIntent)"
                    )
                    InspectorMenuState.shared.windowBecameKey(setting.visibility)
                    try await waitUntil("inspector menu routes through key-window identity seam") {
                        InspectorMenuState.shared.isKeyWindowInspectorPresented == true
                    }
                    InspectorMenuState.shared.toggleKeyWindowInspector()
                    try await waitUntil("explicit hide persists") { !setting.value }
                    host.window.setContentSize(NSSize(width: 900, height: 680))
                    host.window.setContentSize(NSSize(width: 1280, height: 680))
                    try await waitUntil("user hidden remains hidden on widening") {
                        self.layoutFrame("inspector", in: host.window) == nil
                    }
                    XCTAssertFalse(setting.value)
                    if state.isPreviewVisible {
                        host.window.setContentSize(NSSize(width: 900, height: 680))
                        try await waitUntil("content is narrow before Show") {
                            host.hostingView.layoutSubtreeIfNeeded()
                            return abs(host.hostingView.bounds.width - 900) <= 0.5
                                && InspectorMenuState.shared.isKeyWindowInspectorPresented == false
                        }
                        // Let the document column record the narrow width before Show.
                        await Task.yield()
                        host.hostingView.layoutSubtreeIfNeeded()
                        try await checkExplicitShow(
                            host: host,
                            setting: setting,
                            inspectorColumnWidth: XCTUnwrap(inspectorColumnWidth)
                        )
                    }
                }
                print("NATIVE_LAYOUT shell=\(shell) layout=\(layout) intent=\(intent) samples=\(requests.count)")
            }
        }
    }

    /// HStack adds the half-screen samples. 1280 stays last so the menu checks run while the inspector fits.
    private func widthRequests(shell: WorkspaceShell) -> [CGFloat] {
        var requests: [CGFloat] = [900, 720, 735, 760, 900]
        if shell == .fixed {
            requests.append(contentsOf: [780, 800, 864])
        }
        requests.append(1280)
        return requests
    }

    /// Explicit Show widens the window by the inspector's deficit, but only within the screen's
    /// visible frame. On a screen too narrow for that (CI's VM display), the intent persists and
    /// the inspector stays collapsed without squeezing the editor or preview.
    private func checkExplicitShow(
        host: HostedWorkspace,
        setting: NativeInspectorIntent,
        inspectorColumnWidth: CGFloat
    ) async throws {
        let window = host.window
        let visible = try XCTUnwrap(window.screen, "Explicit Show widens within the window's screen").visibleFrame
        let editor = try XCTUnwrap(layoutFrame("editor", in: window))
        let available = host.hostingView.bounds.width - editor.minX
        let required = WorkspaceLayout.contentMinimum(preview: true) + inspectorColumnWidth
        let neededWindowWidth = window.frame.width + required - available
        let fits = neededWindowWidth <= visible.width + 0.5
        let diagnostics = "branch=\(fits ? "widen" : "screen-limited") visibleFrame=\(visible) required=\(required) "
            + "available=\(available) neededWindowWidth=\(neededWindowWidth)"
        print("INSPECTOR_SHOW \(diagnostics)")
        InspectorMenuState.shared.toggleKeyWindowInspector()
        if fits {
            try await waitUntil("explicit Show persists and widens to fit (\(diagnostics))") {
                setting.value && self.layoutFrame("inspector", in: window) != nil
            }
            XCTAssertGreaterThanOrEqual(window.frame.width, neededWindowWidth - 0.5, diagnostics)
        } else {
            try await waitUntil("explicit Show persists and grows to the screen (\(diagnostics))") {
                host.hostingView.layoutSubtreeIfNeeded()
                return setting.value && abs(window.frame.width - visible.width) <= 0.5
            }
            XCTAssertNil(layoutFrame("inspector", in: window), diagnostics)
            XCTAssertEqual(InspectorMenuState.shared.isKeyWindowInspectorPresented, false, diagnostics)
        }
        XCTAssertTrue(setting.value, diagnostics)
        XCTAssertLessThanOrEqual(window.frame.width, visible.width + 0.5, diagnostics)
        try await assertNativeLayout(in: window, preview: true)
    }

    private func assertNativeLayout(in window: NSWindow, preview: Bool) async throws {
        let editor = try XCTUnwrap(layoutFrame("editor", in: window))
        XCTAssertGreaterThanOrEqual(editor.width, WorkspaceLayout.editorMinimum - 0.5)
        var frames = [editor]
        if preview {
            let rendered = try XCTUnwrap(layoutFrame("preview", in: window))
            XCTAssertGreaterThanOrEqual(rendered.width, WorkspaceLayout.previewMinimum - 0.5)
            frames.append(rendered)
        }
        for name in ["handle", "inspector"] {
            if let frame = layoutFrame(name, in: window) { frames.append(frame) }
        }
        for left in frames.indices {
            for right in frames.indices where right > left {
                XCTAssertLessThanOrEqual(frames[left].intersection(frames[right]).width, 0.5,
                                         "Columns must not overlap: \(frames)")
            }
            XCTAssertGreaterThanOrEqual(frames[left].minX, -0.5)
            XCTAssertLessThanOrEqual(frames[left].maxX, try XCTUnwrap(window.contentView).bounds.width + 0.5)
        }
    }

    private func layoutFrame(_ name: String, in window: NSWindow) -> NSRect? {
        guard let view = firstDescendant(of: NSView.self, in: window.contentView, where: {
            $0.identifier?.rawValue == "plainsong.layout.\(name)"
        }), view.window != nil else { return nil }
        return view.convert(view.bounds, to: window.contentView)
    }

    private func makeNativeLayoutHost(appState: AppState, shell: WorkspaceShell,
                                      setting: NativeInspectorIntent) -> HostedWorkspace
    {
        EditorPreviewScrollCoordinator.latestDebugInstance = nil
        let disposal = HostedRootDisappearance()
        let lifecycle = HostedPreviewLifecycle()
        let root = NativeLayoutRoot(setting: setting, shell: shell)
            .environmentObject(appState).onDisappear { disposal.markDisposed() }
        let hosting = NSHostingView(rootView: AnyView(root))
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1280, height: 680),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        lifecycle.capture(EditorPreviewScrollCoordinator.latestDebugInstance?.previewControllerForTesting)
        return HostedWorkspace(window: window, hostingView: hosting, disposal: disposal, previewLifecycle: lifecycle)
    }
}

@MainActor
private final class NativeInspectorIntent: ObservableObject {
    @Published var value: Bool
    @Published var width = InspectorLayout.defaultWidth
    let visibility: InspectorVisibility
    init(_ value: Bool) {
        self.value = value
        visibility = InspectorVisibility(userIntent: value)
    }
}

private struct NativeLayoutRoot: View {
    @ObservedObject var setting: NativeInspectorIntent
    let shell: WorkspaceShell
    var body: some View {
        WorkspaceWindow(
            shellOverride: shell,
            inspectorIntentOverride: $setting.value,
            inspectorWidthOverride: $setting.width,
            inspectorVisibilityOverride: setting.visibility,
            sidebarIdealWidth: 320, sidebarMinimumWidth: 320
        )
    }
}
