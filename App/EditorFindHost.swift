import AppKit
import EditorKit
import Foundation

/// App-owned in-document find runtime (controller + chrome bookkeeping).
///
/// Stored as one property on `AppState` so the find surface does not inflate
/// `AppState.swift` past the file-length gate. UI chrome is still published by
/// reassigning `ui` through AppState accessors.
/// Cached editor selection for ⌘E / caret anchor.
///
/// Scoped to one document identity **and one source revision**: offsets only mean anything
/// against the exact text they were read from, so a same-URL Reload must invalidate them the
/// same way a document switch does.
struct EditorFindCachedSelection: Equatable {
    let documentIdentity: EditorDocumentIdentity?
    let sourceRevision: Int
    let range: NSRange
}

@MainActor
final class EditorFindHost {
    let controller = EditorFindController()
    /// Monotonic Replace authority generation and its diagnostics (Replace PR E).
    let replaceAuthority = EditorReplaceAuthorityState()
    let replaceBatch = EditorReplaceBatchRuntime()
    let replaceMarkedTextOwners = EditorReplaceMarkedTextOwners()
    var ui = EditorFindUIState()
    /// Materialized once per controller session change so ordinary SwiftUI updates do not map
    /// the retained (up to 10,000) match list back into `NSRange`s again.
    var matchHighlightRequest: EditorFindMatchHighlightRequest?
    var presentationTask: Task<Void, Never>?
    /// Last find navigation ID already published on `editorNavigationCommand`.
    var lastPublishedFindNavigationID: UInt64?
    /// Selection snapshot for ⌘E / caret — never reuse across document identities or revisions.
    var latestKnownEditorSelection: EditorFindCachedSelection?
    /// Ensures `onSessionDidChange` is wired once to AppState.
    var didInstallSessionObserver = false
    /// Reported SwiftUI find-bar focus, **keyed by window number**.
    ///
    /// One entry per window: `AppState` is shared across the `WindowGroup` and each window's
    /// bar keeps its own `FocusState`, so a single slot would let whichever window wrote last
    /// silently own eligibility. A window clears only its own entry; every entry is dropped
    /// only where the bar itself goes away (Escape / Done, last document closed, workspace
    /// closed) — **not** on an ordinary document switch, which keeps the bar open per F4b.
    var chromeFocusByWindow: [Int: EditorFindChromeFocus] = [:]
    /// Test seam: when non-`nil`, replaces key-window first-responder eligibility checks.
    var commandContextOverride: Bool?
    /// Test seam: when non-`nil`, stands in for `NSApp.keyWindow?.windowNumber`.
    ///
    /// Only *which window is key* is stubbed — the report-versus-key comparison that decides
    /// eligibility still runs, so a cross-window regression is observable.
    var keyWindowNumberOverride: Int?
    /// Test seam: when non-`nil`, stands in for `NSApp.keyWindow` in the AppKit responder
    /// branch of `isEditorFindCommandContextActive()`. The window's real first responder is
    /// still inspected; only which window is key is designated (hosted tests cannot make a
    /// window really key). An installed override is authoritative even when it returns `nil`.
    var keyWindowOverride: (() -> NSWindow?)?

    // MARK: Replacement row (Replace PR H)

    /// Last result or refusal shown in the replacement row; `nil` when nothing applies.
    var replaceStatus: EditorReplaceStatus?
    /// Advanced by every row action and by every lifecycle reset, so a Replace All that
    /// finishes after either never writes a stale message into the row.
    var replaceStatusSerial: UInt64 = 0
    /// The bar's own Replace All task. Cancellation goes through the batch runtime, not this.
    var replaceAllTask: Task<Void, Never>?
    /// Spoken copy of the last announced status, for tests; announcements are fire-and-forget.
    var lastReplaceAnnouncement: String?
    var didInstallReplacePresentation = false
    var didAnnounceReplacePreparation = false
    var isBlockedStatusCheckPending = false
    var isReplacePresentationPublishPending = false

    // Handoff 27b flake trace: every silent hop between a bar Replace All press and
    // `EditorReplaceBatchPreparation.prepare`. Read only by hosted timeout diagnostics.
    #if DEBUG
        private(set) var replaceBarTrace: [String] = []
    #endif

    /// Records one `replaceBarTrace` entry with a monotonic uptime stamp and the call site.
    /// A no-op outside DEBUG; never consulted for behavior.
    func traceReplaceBarAction(
        _ message: @autoclosure () -> String,
        fileID: StaticString = #fileID,
        line: UInt = #line
    ) {
        #if DEBUG
            if replaceBarTrace.count >= 64 {
                replaceBarTrace.removeFirst(replaceBarTrace.count - 63)
            }
            let milliseconds = Int(ProcessInfo.processInfo.systemUptime * 1000)
            replaceBarTrace.append("+\(milliseconds)ms \(message()) (\(fileID):\(line))")
        #endif
    }

    /// `traceReplaceBarAction` for the detached preparation worker: the entry lands on the
    /// next main turn, ordered behind anything already queued there.
    nonisolated func traceReplaceBarActionOffMain(_ message: String) {
        Task { @MainActor in traceReplaceBarAction(message) }
    }

    init() {
        // An authority advance supersedes every plan; a preparing one stops at once instead
        // of draining to a refusal behind a still-visible progress label.
        replaceAuthority.onAdvance = { [weak self, weak replaceBatch] in
            self?.traceReplaceBarAction(
                "authorityAdvance supersededPreparing=\(replaceBatch?.isPreparing ?? false)"
            )
            replaceBatch?.supersedeIfPreparing()
        }
    }
}

#if DEBUG
    /// Compact caller chain for `replaceBarTrace` (handoff 27b): the calling thread's
    /// frames inside the App module, innermost first, joined by " <- ". Pure symbol
    /// formatting — safe on any thread, and it captures the producing call site rather
    /// than a queued trampoline.
    func editorFindTraceCallerFrames(limit: Int = 8) -> String {
        Thread.callStackSymbols
            .lazy
            .filter { $0.contains("Plainsong") }
            .dropFirst()
            .prefix(limit)
            .map { frame -> String in
                // "<idx> <image> 0x<addr> <symbol tokens…>": keep everything after the
                // address so a frame reads as "symbol + offset".
                let parts = frame.split(whereSeparator: { $0 == " " || $0 == "\t" })
                guard parts.count > 3 else {
                    return frame.trimmingCharacters(in: .whitespaces)
                }
                return parts.dropFirst(3).joined(separator: " ")
            }
            .joined(separator: " <- ")
    }
#endif
