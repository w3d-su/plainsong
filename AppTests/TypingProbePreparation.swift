import AppKit
@testable import EditorKit
import XCTest

@MainActor
enum TypingProbePreparation {
    struct ManualTrimPlan {
        let chunks: Int
        let initialLength: Int
        let navigatingAfter: Int
        let navigationRange: NSRange
        let yieldMilliseconds: Int
        let drawAfterTrim: Int?
        let layoutBetweenTrims: Bool
        let useAdmission: Bool
    }

    /// Keep the original synchronous trim/draw/navigation sequence, optionally asking
    /// the real production planner to admit each chunk against the current viewport.
    static func manualTrim(
        _ plan: ManualTrimPlan,
        in editor: MarkdownSTTextView,
        cancelling trimmer: EditorTextElementCacheTrimmer?
    ) async throws -> (ranges: [[String: Int]], navigated: Bool) {
        var end = plan.initialLength
        var ranges: [[String: Int]] = []
        var navigated = false
        for chunkIndex in 0 ..< plan.chunks {
            guard end >= EditorTextElementCacheTrimmer.chunkLength else { break }
            let candidate = NSRange(location: end - EditorTextElementCacheTrimmer.chunkLength,
                                    length: EditorTextElementCacheTrimmer.chunkLength)
            let range: NSRange
            if plan.useAdmission {
                guard let admitted = EditorTextElementCacheTrimmer.protectedChunk(candidate, in: editor) else { break }
                range = admitted
            } else {
                range = candidate
            }
            // Admission and this capture are synchronous in the same main-actor turn.
            // Read the native viewport directly; the general helper can fall back to selection.
            let entry = plan.useAdmission ? admissionState(range, in: editor)
                : ["location": range.location, "length": range.length]
            let trimmed = EditorTextElementCacheTrimmer.trim(range, in: editor)
            _ = try XCTUnwrap(trimmed ? range : nil, "Explicit cache trim must succeed")
            ranges.append(entry)
            if plan.drawAfterTrim == 0 || chunkIndex + 1 == plan.drawAfterTrim {
                try drawGutter(in: editor)
            }
            end = range.location
            if chunkIndex + 1 == plan.navigatingAfter {
                editor.textSelection = plan.navigationRange
                editor.scrollRangeToVisible(editor.selectedRange())
                navigated = true
                try await settle(nanoseconds: 10_000_000, cancelling: trimmer)
            }
            if plan.layoutBetweenTrims {
                editor.needsLayout = true
                editor.layoutSubtreeIfNeeded()
            }
            if plan.yieldMilliseconds > 0 {
                try await settle(nanoseconds: UInt64(plan.yieldMilliseconds) * 1_000_000, cancelling: trimmer)
            }
        }
        return (ranges, navigated)
    }

    private static func admissionState(_ range: NSRange, in editor: MarkdownSTTextView) -> [String: Int] {
        let selection = editor.selectedRange()
        var entry = [
            "location": range.location,
            "length": range.length,
            "nativeViewportBeforeLocation": -1,
            "nativeViewportBeforeLength": 0,
            "viewportPrefetchBeforeEnd": -1,
            "selectionBeforeLocation": selection.location,
            "selectionBeforeLength": selection.length,
            "selectedParagraphBeforeLocation": -1,
            "selectedParagraphBeforeLength": 0,
            "selectedProtectionBeforeStart": -1,
            "selectedProtectionBeforeEnd": -1,
        ]
        guard let storage = MarkdownTextView.textStorage(of: editor) else { return entry }
        if let viewport = editor.textLayoutManager.textViewportLayoutController.viewportRange, !viewport.isEmpty {
            let manager = editor.textContentManager
            let documentStart = manager.documentRange.location
            let start = manager.offset(from: documentStart, to: viewport.location)
            let end = manager.offset(from: documentStart, to: viewport.endLocation)
            if start != NSNotFound, end != NSNotFound, start >= 0, end > start, end <= storage.length {
                entry["nativeViewportBeforeLocation"] = start
                entry["nativeViewportBeforeLength"] = end - start
                entry["viewportPrefetchBeforeEnd"] = min(storage.length, end + max(end - start, 8192))
            }
        }
        if selection.location != NSNotFound, selection.location >= 0, selection.length >= 0,
           selection.location <= storage.length, selection.length <= storage.length - selection.location
        {
            let paragraphs = storage.mutableString.paragraphRange(for: selection)
            entry["selectedParagraphBeforeLocation"] = paragraphs.location
            entry["selectedParagraphBeforeLength"] = paragraphs.length
            entry["selectedProtectionBeforeStart"] = max(0, paragraphs.location - 8192)
            entry["selectedProtectionBeforeEnd"] = min(storage.length, NSMaxRange(paragraphs) + 8192)
        }
        return entry
    }

    /// Cancel every 100 ms so a viewport notification cannot restart a coordinator
    /// trim while an explicitly selected cache state settles.
    static func settle(nanoseconds: UInt64, cancelling trimmer: EditorTextElementCacheTrimmer?) async throws {
        guard let trimmer else {
            try await Task.sleep(nanoseconds: nanoseconds)
            return
        }
        var remaining = nanoseconds
        while remaining > 0 {
            trimmer.cancel()
            let delay = min(remaining, 100_000_000)
            try await Task.sleep(nanoseconds: delay)
            remaining -= delay
        }
        trimmer.cancel()
    }

    /// Force the actual draw callback without AppKit display preparation, which may
    /// otherwise perform native layout before drawing and hide the ordering under test.
    static func drawGutter(in editor: MarkdownSTTextView) throws {
        guard let gutter = editor.lineNumberGutter,
              !gutter.isHiddenOrHasHiddenAncestor,
              gutter.bounds.width > 0,
              gutter.bounds.height > 0
        else {
            return
        }
        let scale = gutter.window?.backingScaleFactor ?? 1
        let width = max(1, Int(ceil(gutter.bounds.width * scale)))
        let height = max(1, Int(ceil(gutter.bounds.height * scale)))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        bitmap.size = gutter.bounds.size
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.cgContext.clear(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        context.cgContext.translateBy(x: 0, y: CGFloat(height))
        context.cgContext.scaleBy(x: scale, y: -scale)
        gutter.effectiveAppearance.performAsCurrentDrawingAppearance {
            gutter.draw(gutter.bounds)
        }
    }

    /// A local production-loop job keeps its captured top range even after navigation.
    /// Coordinator jobs are cancelled while waiting, so both guarded and unguarded
    /// implementations see exactly the same deliberately stale job admission.
    static func productionTrim(
        chunks: Int,
        navigatingAfter navigationChunk: Int,
        to navigationRange: NSRange,
        in editor: MarkdownSTTextView
    ) async throws -> [[String: Int]] {
        let coordinator = try XCTUnwrap(editor.textDelegate as? MarkdownTextViewCoordinator)
        let coordinatorTrimmer = coordinator.textElementCacheTrimmer
        coordinatorTrimmer.cancel()
        let trimmer = EditorTextElementCacheTrimmer()
        let recordEvent = coordinatorTrimmer.probeHandler
        var ranges: [[String: Int]] = []
        var navigated = false
        var finished = false
        trimmer.probeHandler = { event, range in
            recordEvent?(event, range)
            if event == "trimmed", let range {
                ranges.append(["location": range.location, "length": range.length])
                if ranges.count == navigationChunk {
                    editor.textSelection = navigationRange
                    editor.scrollRangeToVisible(editor.selectedRange())
                    navigated = true
                }
                if ranges.count == chunks {
                    finished = true
                    trimmer.cancel()
                }
            }
            if event == "refused" || event == "complete" {
                finished = true
            }
        }
        defer {
            trimmer.cancel()
            trimmer.probeHandler = nil
            coordinatorTrimmer.cancel()
        }
        guard chunks > 0 else { return [] }
        if navigationChunk > 0 {
            _ = try XCTUnwrap(navigationChunk <= chunks ? navigationChunk : nil,
                              "Navigation must occur within the requested trim chunks")
        }
        let visible = try XCTUnwrap(MarkdownTextView.visibleTextRange(of: editor))
        XCTAssertLessThan(NSMaxRange(visible), navigationRange.location,
                          "Stale-job preparation must capture a viewport above the navigation target")
        trimmer.visibleRangeDidChange(visible, in: editor) { [weak coordinator] in
            guard let coordinator else { return false }
            return !coordinator.isUpdating && !coordinator.hasPendingWriterLease
        }
        let deadline = Date().addingTimeInterval(10)
        while !finished, Date() < deadline {
            // Do not cancel the local job: it models a task that is still admitted
            // with its old capture before the asynchronous bounds reporter replaces it.
            coordinatorTrimmer.cancel()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(finished, "The stale production-loop job must reach a boundary or refuse a chunk")
        if navigationChunk > 0 {
            XCTAssertTrue(navigated, "The production-loop job must reach the selected navigation boundary")
            XCTAssertGreaterThanOrEqual(ranges.count, navigationChunk)
        } else {
            XCTAssertEqual(ranges.count, chunks, "An unchanged viewport must reach the requested boundary")
        }
        return ranges
    }
}
