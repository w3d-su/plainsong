import AppKit
@testable import EditorKit

/// Counts TextKit paragraph cache misses without replacing its default paragraphs.
/// The hosted typing probe retains this delegate only while diagnostics are enabled.
final class TypingProbeParagraphRequests: NSObject, NSTextContentStorageDelegate {
    private static let retainedRangeCount = 8
    private var viewport: NSRange?
    private let captureOutsideCallStack: Bool
    let captureBeyondLocation: Int?
    private(set) var requestCount = 0
    private(set) var requestedUTF16Length = 0
    private(set) var outsideViewportRequestCount = 0
    private(set) var firstRequestedRanges: [NSRange] = []
    private(set) var lastRequestedRanges: [NSRange] = []
    private(set) var firstOutsideViewportCallStack: [String]?
    private(set) var firstBeyondLocationCallStack: [String]?
    private(set) var firstBeyondLocationRange: NSRange?
    private var minimumRequestedLocation: Int?
    private var maximumRequestedEnd: Int?

    init(
        viewport: NSRange?,
        captureOutsideCallStack: Bool = false,
        captureBeyondLocation: Int? = nil
    ) {
        self.viewport = viewport
        self.captureOutsideCallStack = captureOutsideCallStack
        self.captureBeyondLocation = captureBeyondLocation
        super.init()
    }

    func textContentStorage(
        _: NSTextContentStorage,
        textParagraphWith range: NSRange
    ) -> NSTextParagraph? {
        requestCount += 1
        requestedUTF16Length += range.length
        minimumRequestedLocation = min(minimumRequestedLocation ?? range.location, range.location)
        maximumRequestedEnd = max(maximumRequestedEnd ?? NSMaxRange(range), NSMaxRange(range))
        if firstRequestedRanges.count < Self.retainedRangeCount {
            firstRequestedRanges.append(range)
        }
        lastRequestedRanges.append(range)
        if lastRequestedRanges.count > Self.retainedRangeCount {
            lastRequestedRanges.removeFirst()
        }
        if let viewport, viewport.location != NSNotFound,
           range.location < viewport.location || NSMaxRange(range) > NSMaxRange(viewport)
        {
            outsideViewportRequestCount += 1
            if captureOutsideCallStack, firstOutsideViewportCallStack == nil {
                firstOutsideViewportCallStack = Thread.callStackSymbols
            }
        }
        if let captureBeyondLocation, range.location >= captureBeyondLocation,
           firstBeyondLocationCallStack == nil
        {
            firstBeyondLocationRange = range
            firstBeyondLocationCallStack = Thread.callStackSymbols
        }
        return nil
    }

    /// Starts another measured phase while keeping the same viewport reference.
    func reset() {
        requestCount = 0
        requestedUTF16Length = 0
        outsideViewportRequestCount = 0
        firstRequestedRanges.removeAll(keepingCapacity: true)
        lastRequestedRanges.removeAll(keepingCapacity: true)
        firstOutsideViewportCallStack = nil
        firstBeyondLocationCallStack = nil
        firstBeyondLocationRange = nil
        minimumRequestedLocation = nil
        maximumRequestedEnd = nil
    }

    /// Starts another phase against a newly captured viewport.
    func reset(viewport: NSRange?) {
        self.viewport = viewport
        reset()
    }

    /// Primitive JSON values, with bounded first/last ranges even for a full-document miss.
    func report() -> [String: Any] {
        var result: [String: Any] = [
            "paragraphRequests": requestCount,
            "paragraphRequestUTF16Length": requestedUTF16Length,
            "paragraphOutsideViewportRequests": outsideViewportRequestCount,
            "paragraphFirstRequests": firstRequestedRanges.map(Self.reportRange),
            "paragraphLastRequests": lastRequestedRanges.map(Self.reportRange),
        ]
        if let viewport {
            result["paragraphReferenceViewport"] = Self.reportRange(viewport)
        }
        if let minimumRequestedLocation, let maximumRequestedEnd {
            result["paragraphRequestedExtent"] = Self.reportRange(NSRange(
                location: minimumRequestedLocation,
                length: maximumRequestedEnd - minimumRequestedLocation
            ))
        }
        if let firstOutsideViewportCallStack {
            result["paragraphFirstOutsideViewportCallStack"] = firstOutsideViewportCallStack
        }
        if let captureBeyondLocation {
            result["paragraphCaptureBeyondLocation"] = captureBeyondLocation
        }
        if let firstBeyondLocationCallStack, let firstBeyondLocationRange {
            result["paragraphFirstBeyondLocationCallStack"] = firstBeyondLocationCallStack
            result["paragraphFirstBeyondLocationRange"] = Self.reportRange(firstBeyondLocationRange)
        }
        return result
    }

    private static func reportRange(_ range: NSRange) -> [String: Int] {
        ["location": range.location, "length": range.length]
    }
}

@MainActor
final class TypingProbeTrimmerEvents {
    private weak var editor: MarkdownSTTextView?
    private let start = DispatchTime.now().uptimeNanoseconds
    private(set) var events: [[String: Any]] = []
    private var observers: [TypingProbeNotificationObserver] = []

    init(editor: MarkdownSTTextView) {
        self.editor = editor
        let center = NotificationCenter.default
        editor.postsFrameChangedNotifications = true
        observers.append(TypingProbeNotificationObserver(center.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: editor,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.record("editor-frame", range: nil) }
        }))
        if let clipView = editor.enclosingScrollView?.contentView {
            clipView.postsBoundsChangedNotifications = true
            observers.append(TypingProbeNotificationObserver(center.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clipView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.record("clip-bounds", range: nil) }
            }))
        }
    }

    func record(_ event: String, range: NSRange?) {
        guard let editor, events.count < 3000 else { return }
        let viewport = MarkdownTextView.visibleTextRange(of: editor)
        events.append([
            "event": event,
            "milliseconds": Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000,
            "rangeLocation": range?.location ?? -1,
            "rangeLength": range?.length ?? 0,
            "viewportLocation": viewport?.location ?? -1,
            "viewportLength": viewport?.length ?? 0,
            "selectionLocation": editor.selectedRange().location,
            "height": editor.frame.height,
            "frameWidth": editor.frame.width,
            "textContainerWidth": editor.textContainer.size.width,
            "clipWidth": editor.enclosingScrollView?.contentView.bounds.width ?? -1,
            "clipHeight": editor.enclosingScrollView?.contentView.bounds.height ?? -1,
            "clipY": editor.enclosingScrollView?.contentView.bounds.minY ?? -1,
        ])
    }
}

private final class TypingProbeNotificationObserver {
    private let token: NSObjectProtocol

    init(_ token: NSObjectProtocol) {
        self.token = token
    }

    deinit {
        NotificationCenter.default.removeObserver(token)
    }
}
