import CryptoKit
import PreviewKit
import QuartzCore
import UIKit

/// What a run types into and listens to. The production target is the scene's editor and
/// preview; a test supplies a bare text view.
@MainActor
struct IOSPerformanceProbeTarget {
    let textView: UITextView
    let documentName: String
    let fileKind: String
    let canWrite: Bool
    var setHighlightObserver: ((() -> Void)?) -> Void = { _ in }
    var setRenderObserver: (((PreviewRenderTiming) -> Void)?) -> Void = { _ in }
    var previewIsVisible: () -> Bool = { false }
}

enum IOSPerformanceProbeFailure: Error, Equatable, CustomStringConvertible {
    case noDocument
    case readOnly
    case composing
    case keystrokeRefused

    var description: String {
        switch self {
        case .noDocument: "Open a document first."
        case .readOnly: "This document is read-only."
        case .composing: "Finish the current text composition first."
        case .keystrokeRefused: "The editor did not accept a keystroke, so the run stopped."
        }
    }
}

/// Types into the open document with `UIKeyInput.insertText`, times each keystroke against
/// the frame clock, then deletes what it typed. UIKit does not consult the delegate for a
/// programmatic insertion; the editor's text view applies the same editing-behavior check
/// in its `insertText` override, so the work per character matches a keyboard commit.
///
/// It measures the app's side of a keystroke. The time until the glyph is lit on the
/// panel needs an external camera and is not measured here. Marked-text (IME) composition
/// is not exercised.
@MainActor
final class IOSPerformanceProbe: ObservableObject {
    enum Phase: Equatable {
        case idle
        case running(String)
        case finished(IOSPerformanceReport)
        case failed(String)
    }

    @Published var isPanelPresented = false
    @Published var configuration = IOSPerformanceProbeConfiguration()
    @Published private(set) var phase: Phase = .idle

    var target: () -> IOSPerformanceProbeTarget? = { nil }
    private var task: Task<Void, Never>?

    var isRunning: Bool {
        if case .running = phase {
            return true
        }
        return false
    }

    func start() {
        guard !isRunning else { return }
        task = Task { [weak self] in
            guard let self else { return }
            do {
                phase = try await .finished(run())
            } catch let failure as IOSPerformanceProbeFailure {
                phase = .failed(failure.description)
            } catch {
                phase = .failed("The run was cancelled.")
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    func reset() {
        guard !isRunning else { return }
        phase = .idle
    }

    func run() async throws -> IOSPerformanceReport {
        guard let target = target() else { throw IOSPerformanceProbeFailure.noDocument }
        guard target.canWrite else { throw IOSPerformanceProbeFailure.readOnly }
        let textView = target.textView
        guard textView.markedTextRange == nil else { throw IOSPerformanceProbeFailure.composing }

        let original = textView.text ?? ""
        let offset = Self.caretOffset(configuration.caret, in: original)
        let wasFirstResponder = textView.isFirstResponder
        if !wasFirstResponder {
            textView.becomeFirstResponder()
        }
        textView.selectedRange = NSRange(location: offset, length: 0)
        textView.scrollRangeToVisible(textView.selectedRange)

        let clock = IOSPerformanceFrameClock()
        clock.start()
        let session = Session(textView: textView, clock: clock, configuration: configuration)
        target.setHighlightObserver { [weak session] in session?.highlightUptime = CACurrentMediaTime() }
        target.setRenderObserver { [weak session] timing in session?.renderTimings.append(timing) }
        let thermalAtStart = ProcessInfo.processInfo.thermalState
        let startedAt = Date()
        defer {
            target.setHighlightObserver(nil)
            target.setRenderObserver(nil)
            clock.stop()
        }

        var failure: Error?
        do {
            // Let the caret move, the keyboard and the first highlight settle.
            try await Task.sleep(nanoseconds: 600_000_000)
            try await session.typeSamples { [weak self] in self?.phase = .running($0) }
            // The last keystroke's own debounced render must not be counted as a sample.
            try await Task.sleep(nanoseconds: 600_000_000)
            try await session.previewSamples { [weak self] in self?.phase = .running($0) }
        } catch {
            failure = error
        }
        let restored = session.restore(offset: offset, original: original)
        if let failure {
            throw failure
        }

        var report = IOSPerformanceReport(
            environment: Self.environment(
                clock: clock,
                thermalAtStart: thermalAtStart,
                wasFirstResponder: wasFirstResponder,
                previewVisible: target.previewIsVisible(),
                startedAt: startedAt
            ),
            document: IOSPerformanceDocument(
                name: target.documentName,
                fileKind: target.fileKind,
                utf8Bytes: original.utf8.count,
                utf16Length: original.utf16.count,
                sha256: SHA256.hash(data: Data(original.utf8)).map { String(format: "%02x", $0) }.joined(),
                caretUTF16Offset: offset
            ),
            configuration: configuration,
            typing: session.typing,
            preview: session.preview,
            previewTimeouts: session.previewTimeouts,
            documentRestored: restored,
            highlightMissing: 0,
            budgets: [],
            inadmissibleReasons: []
        )
        report.summarize()
        return report
    }

    /// Start and end are the document's ends; middle is the start of the line that holds
    /// the midpoint, so the run never splits a surrogate pair or a grapheme.
    static func caretOffset(_ caret: IOSPerformanceProbeConfiguration.Caret, in text: String) -> Int {
        let source = text as NSString
        switch caret {
        case .start: return 0
        case .end: return source.length
        case .middle:
            guard source.length > 0 else { return 0 }
            return source.lineRange(for: NSRange(location: source.length / 2, length: 0)).location
        }
    }

    private static func environment(
        clock: IOSPerformanceFrameClock,
        thermalAtStart: ProcessInfo.ThermalState,
        wasFirstResponder: Bool,
        previewVisible: Bool,
        startedAt: Date
    ) -> IOSPerformanceEnvironment {
        let info = Bundle.main.infoDictionary ?? [:]
        #if DEBUG
            let buildConfiguration = "Debug"
        #else
            let buildConfiguration = "Release"
        #endif
        return IOSPerformanceEnvironment(
            deviceModel: deviceModel(),
            systemVersion: UIDevice.current.systemVersion,
            appVersion: info["CFBundleShortVersionString"] as? String ?? "",
            appBuild: info["CFBundleVersion"] as? String ?? "",
            buildConfiguration: buildConfiguration,
            maximumFramesPerSecond: UIScreen.main.maximumFramesPerSecond,
            frameIntervalMilliseconds: clock.lastFrameInterval.map { $0 * 1000 },
            thermalStateAtStart: thermalAtStart.probeName,
            thermalStateAtEnd: ProcessInfo.processInfo.thermalState.probeName,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            editorWasFirstResponder: wasFirstResponder,
            previewWasVisible: previewVisible,
            startedAt: startedAt
        )
    }

    private static func deviceModel() -> String {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { bytes in
            String(bytes: bytes.prefix { $0 != 0 }, encoding: .utf8) ?? "unknown"
        }
    }
}

extension ProcessInfo.ThermalState {
    var probeName: String {
        switch self {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}

/// One run's mutable state: what it typed, and what the observers reported.
@MainActor
private final class Session {
    let textView: UITextView
    let clock: IOSPerformanceFrameClock
    let configuration: IOSPerformanceProbeConfiguration
    var typing: [IOSPerformanceTypingSample] = []
    var preview: [IOSPerformancePreviewSample] = []
    var previewTimeouts = 0
    var highlightUptime: CFTimeInterval?
    var renderTimings: [PreviewRenderTiming] = []
    private var inserted = 0

    init(textView: UITextView, clock: IOSPerformanceFrameClock, configuration: IOSPerformanceProbeConfiguration) {
        self.textView = textView
        self.clock = clock
        self.configuration = configuration
    }

    /// Returns the time just before the insertion and just after it returned.
    private func typeOne() throws -> (start: CFTimeInterval, returned: CFTimeInterval) {
        guard textView.markedTextRange == nil else { throw IOSPerformanceProbeFailure.composing }
        let length = textView.textStorage.length
        highlightUptime = nil
        let start = CACurrentMediaTime()
        textView.insertText("x")
        let returned = CACurrentMediaTime()
        guard textView.textStorage.length == length + 1 else {
            throw IOSPerformanceProbeFailure.keystrokeRefused
        }
        inserted += 1
        return (start, returned)
    }

    func typeSamples(progress: (String) -> Void) async throws {
        let total = configuration.warmUpCount + configuration.sampleCount
        let interval = Double(configuration.keystrokeIntervalMilliseconds) / 1000
        let highlightWait = Double(configuration.highlightWaitMilliseconds) / 1000
        for index in 0 ..< total {
            try Task.checkCancellation()
            if index % 10 == 0 {
                progress("Typing \(index) of \(total)")
            }
            let (start, returned) = try typeOne()
            let committed = await clock.afterCommit()
            let refreshed = await clock.refresh(atOrAfter: committed)
            while highlightUptime == nil, CACurrentMediaTime() - start < highlightWait {
                try await Task.sleep(nanoseconds: 4_000_000)
            }
            let highlighted = highlightUptime
            if index >= configuration.warmUpCount {
                typing.append(IOSPerformanceTypingSample(
                    index: index - configuration.warmUpCount,
                    insertMilliseconds: (returned - start) * 1000,
                    commitMilliseconds: (committed - start) * 1000,
                    refreshMilliseconds: (refreshed - start) * 1000,
                    highlightMilliseconds: highlighted.map { ($0 - start) * 1000 }
                ))
            }
            let remaining = interval - (CACurrentMediaTime() - start)
            if remaining > 0 {
                try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
        }
    }

    /// Each sample types one character and waits for the render PreviewKit sends for it.
    /// Three timeouts in a row end the phase: the preview is not rendering.
    func previewSamples(progress: (String) -> Void) async throws {
        let wait = Double(configuration.previewWaitMilliseconds) / 1000
        var consecutiveTimeouts = 0
        for index in 0 ..< configuration.previewSampleCount where consecutiveTimeouts < 3 {
            try Task.checkCancellation()
            progress("Preview \(index) of \(configuration.previewSampleCount)")
            renderTimings.removeAll()
            let (start, _) = try typeOne()
            var timing: PreviewRenderTiming?
            while timing == nil, CACurrentMediaTime() - start < wait {
                try await Task.sleep(nanoseconds: 10_000_000)
                timing = renderTimings.first { $0.sentUptime >= start }
            }
            guard let timing else {
                previewTimeouts += 1
                consecutiveTimeouts += 1
                continue
            }
            consecutiveTimeouts = 0
            preview.append(IOSPerformancePreviewSample(
                index: index,
                version: timing.version,
                renderMilliseconds: timing.duration * 1000,
                editToCompleteMilliseconds: (timing.completedUptime - start) * 1000
            ))
        }
    }

    /// Deletes exactly the characters this run typed and reports whether the text is the
    /// starting text again.
    func restore(offset: Int, original: String) -> Bool {
        guard inserted > 0, textView.markedTextRange == nil else {
            return (textView.text ?? "") == original
        }
        let typed = NSRange(location: offset, length: inserted)
        let source = (textView.text ?? "") as NSString
        if NSMaxRange(typed) <= source.length,
           source.substring(with: typed) == String(repeating: "x", count: inserted)
        {
            textView.selectedRange = NSRange(location: NSMaxRange(typed), length: 0)
            for _ in 0 ..< inserted {
                textView.deleteBackward()
            }
        }
        inserted = 0
        return (textView.text ?? "") == original
    }
}
