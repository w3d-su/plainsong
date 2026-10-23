@testable import EditorKitIOS
import MarkdownCore
import SyntaxKit
import UIKit
import XCTest

@MainActor
final class IOSEditorHarness {
    let window: UIWindow
    let controller: IOSSourceEditorController
    let session: DocumentSession
    let identity = IOSDocumentIdentity(rawValue: UUID())
    let bindingID = UUID()
    let debounce: IOSDebounceGate?
    let syntax: IOSGatedTokenizer?
    private let root = UIViewController()

    init(
        text: String,
        tokenizer: (any MarkdownSyntaxTokenizing)? = nil,
        debounce: IOSDebounceGate? = nil,
        syntax: IOSGatedTokenizer? = nil,
        focused: Bool = true,
        viewport: NSRange? = nil
    ) {
        self.debounce = debounce
        self.syntax = syntax
        session = DocumentSession(text: text, isDirty: false)
        if let debounce {
            controller = IOSSourceEditorController(
                syntaxTokenizer: tokenizer,
                theme: .light,
                debounce: { await debounce.wait() }
            )
        } else {
            controller = IOSSourceEditorController(syntaxTokenizer: tokenizer, theme: .light)
        }
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root
        window.makeKeyAndVisible()
        controller.textView.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        controller.textView.viewportOverride = viewport
        root.view.addSubview(controller.textView)
        controller.attach(IOSSourceEditorDocumentBinding(
            bindingID: bindingID,
            identity: identity,
            session: session,
            accessGeneration: 1,
            canWrite: true
        ))
        if focused {
            controller.updateCommandFocus(for: identity, bindingID: bindingID, isFocused: true)
        }
        _ = controller.textView.becomeFirstResponder()
    }

    var textView: IOSMarkdownTextView {
        controller.textView
    }

    func edit(
        _ result: MarkdownEditResult,
        name: String = "Format",
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> IOSAuthorizedEdit {
        let snapshot = try XCTUnwrap(controller.captureSnapshot(), file: file, line: line)
        return IOSAuthorizedEdit(
            bindingID: snapshot.bindingID,
            baseRevision: snapshot.revision,
            selectionGeneration: snapshot.selectionGeneration,
            accessGeneration: snapshot.accessGeneration,
            result: result,
            undoActionName: name
        )
    }

    func placeCaret(at location: Int) {
        textView.selectedRange = NSRange(location: location, length: 0)
    }

    func syntaxToken(at location: Int) -> String? {
        guard location >= 0, location < textView.textStorage.length else { return nil }
        return textView.textStorage.attribute(
            IOSSyntaxAttribute.key,
            at: location,
            effectiveRange: nil
        ) as? String
    }
}

final class IOSDebounceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Bool, Never>] = []

    func wait() async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            continuations.append(continuation)
            lock.unlock()
        }
    }

    var waiting: Int {
        lock.lock()
        defer { lock.unlock() }
        return continuations.count
    }

    func releaseNext(accepted: Bool = true) {
        lock.lock()
        let continuation = continuations.removeFirst()
        lock.unlock()
        continuation.resume(returning: accepted)
    }
}

actor IOSSyntaxGate {
    private struct Pending {
        let request: SyntaxRequest
        let continuation: CheckedContinuation<SyntaxResult, Error>
    }

    private var pending: [Pending] = []
    private(set) var requests: [SyntaxRequest] = []
    private var inFlight = 0
    private(set) var maxInFlight = 0

    func tokens(for request: SyntaxRequest) async throws -> SyntaxResult {
        requests.append(request)
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        defer { inFlight -= 1 }
        return try await withCheckedThrowingContinuation { continuation in
            pending.append(Pending(request: request, continuation: continuation))
        }
    }

    func pendingCount() -> Int {
        pending.count
    }

    func requestCount() -> Int {
        requests.count
    }

    func maximumInFlight() -> Int {
        maxInFlight
    }

    func request(at index: Int) -> SyntaxRequest? {
        requests.indices.contains(index) ? requests[index] : nil
    }

    func resumeFirst(kind: MarkdownSyntaxToken.Kind) {
        let item = pending.removeFirst()
        let covered = item.request.visibleRange
        let tokenRange = covered.length > 0 ? covered : NSRange(location: 0, length: 0)
        let tokens = tokenRange.length > 0
            ? [MarkdownSyntaxToken(kind: kind, range: tokenRange)]
            : []
        item.continuation.resume(returning: SyntaxResult(
            requestID: item.request.requestID,
            version: item.request.version,
            coveredRange: covered,
            tokens: tokens
        ))
    }
}

final class IOSGatedTokenizer: MarkdownSyntaxTokenizing, @unchecked Sendable {
    let gate = IOSSyntaxGate()

    func tokens(for request: SyntaxRequest) async throws -> SyntaxResult {
        try await gate.tokens(for: request)
    }
}

final class IOSScanProbe: MarkdownSyntaxTokenizing, @unchecked Sendable {
    private let lock = NSLock()
    private var offMain = false
    private var nanoseconds: UInt64 = 0

    func tokens(for request: SyntaxRequest) async throws -> SyntaxResult {
        let clock = ContinuousClock()
        let started = clock.now
        let (leftMain, newlines) = await Task.detached(priority: .userInitiated) { () -> (Bool, Int) in
            var newlines = 0
            let storage = request.source as NSString
            for index in 0 ..< storage.length where storage.character(at: index) == 10 {
                newlines += 1
            }
            return (!Thread.isMainThread, newlines)
        }.value
        let elapsed = clock.now - started
        lock.lock()
        offMain = leftMain
        nanoseconds = UInt64(elapsed.components.seconds) * 1_000_000_000
            + UInt64(elapsed.components.attoseconds / 1_000_000_000)
        lock.unlock()
        _ = newlines
        return SyntaxResult(
            requestID: request.requestID,
            version: request.version,
            coveredRange: request.visibleRange,
            tokens: []
        )
    }

    var ranOffMain: Bool {
        lock.lock()
        defer { lock.unlock() }
        return offMain
    }

    var elapsedNanoseconds: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return nanoseconds
    }
}

@MainActor
func iosWaitUntil(
    _ description: String,
    file: StaticString = #filePath,
    line: UInt = #line,
    check: () async -> Bool
) async {
    for _ in 0 ..< 200 {
        if await check() {
            return
        }
        await Task.yield()
    }
    XCTFail("timed out waiting for \(description)", file: file, line: line)
}

func iosUTF16(_ text: String) -> Int {
    (text as NSString).length
}
