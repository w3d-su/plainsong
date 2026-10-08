import UIKit

/// UIDocument's Objective-C callbacks are nonisolated. A separate Sendable relay
/// crosses to MainActor without transferring the live UIDocument into a task.
private final class DocumentCallbacks: @unchecked Sendable {
    @MainActor var autosave: (@MainActor @Sendable (@escaping @Sendable (Bool) -> Void) -> Void)?
    @MainActor var revert: (@MainActor @Sendable (URL, (@Sendable (Bool) -> Void)?) -> Void)?
    @MainActor var editing: (@MainActor @Sendable (Bool) -> Void)?
}

/// UIDocument invokes content methods on file-access queues. Only immutable UTF-8
/// bytes cross that boundary; UITextView remains the editable source authority.
final class SpikeDocument: UIDocument, @unchecked Sendable {
    private let contentsLock = NSLock()
    private var loaded = Data()
    private var capturedWrite: Data?
    private var expectedDisk: Data?
    private let callbacks = DocumentCallbacks()
    @MainActor var requestAutosave: (@MainActor @Sendable (@escaping @Sendable (Bool) -> Void) -> Void)? {
        get { callbacks.autosave }
        set { callbacks.autosave = newValue }
    }

    @MainActor var requestRevert: (@MainActor @Sendable (URL, (@Sendable (Bool) -> Void)?) -> Void)? {
        get { callbacks.revert }
        set { callbacks.revert = newValue }
    }

    @MainActor var editingAvailability: (@MainActor @Sendable (Bool) -> Void)? {
        get { callbacks.editing }
        set { callbacks.editing = newValue }
    }

    var loadedSource: String {
        contentsLock.lock()
        defer { contentsLock.unlock() }
        return String(decoding: loaded, as: UTF8.self)
    }

    override func load(fromContents contents: Any, ofType _: String?) throws {
        guard let data = contents as? Data, String(data: data, encoding: .utf8) != nil else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        contentsLock.lock()
        loaded = data
        contentsLock.unlock()
    }

    override func contents(forType _: String) throws -> Any {
        contentsLock.lock()
        defer { contentsLock.unlock() }
        guard let capturedWrite else { throw CocoaError(.fileWriteUnknown) }
        return capturedWrite
    }

    @MainActor
    func persist(_ source: String, baseline: String, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        contentsLock.lock()
        capturedWrite = Data(source.utf8)
        expectedDisk = Data(baseline.utf8)
        contentsLock.unlock()
        super.save(to: fileURL, for: .forOverwriting) { [weak self] success in
            self?.contentsLock.lock()
            self?.capturedWrite = nil
            self?.expectedDisk = nil
            self?.contentsLock.unlock()
            Task { @MainActor in completion(success) }
        }
    }

    override func writeContents(_ contents: Any, to url: URL, for saveOperation: UIDocument.SaveOperation,
                                originalContentsURL: URL?) throws
    {
        contentsLock.lock()
        let baseline = expectedDisk
        contentsLock.unlock()
        // UIDocument calls this within its coordinated safe-write transaction.
        // Fail closed when the provider cannot supply readable original bytes.
        guard saveOperation == .forOverwriting, let baseline,
              try Data(contentsOf: originalContentsURL ?? fileURL) == baseline
        else {
            throw CocoaError(.fileWriteFileExists)
        }
        try super.writeContents(contents, to: url, for: saveOperation, originalContentsURL: originalContentsURL)
    }

    /// All automatic saves must use the same captured-revision writer as Save.
    override func autosave(completionHandler: (@Sendable (Bool) -> Void)? = nil) {
        let relay = callbacks
        Task { @MainActor in
            guard let requestAutosave = relay.autosave else { completionHandler?(false); return }
            requestAutosave { completionHandler?($0) }
        }
    }

    override func revert(toContentsOf url: URL, completionHandler: (@Sendable (Bool) -> Void)? = nil) {
        let relay = callbacks
        Task { @MainActor in
            guard let requestRevert = relay.revert else { completionHandler?(false); return }
            requestRevert(url, completionHandler)
        }
    }

    @MainActor
    func coordinatedRevert(to url: URL, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        super.revert(toContentsOf: url) { success in
            Task { @MainActor in completion(success) }
        }
    }

    override func disableEditing() {
        let relay = callbacks
        Task { @MainActor in relay.editing?(false) }
    }

    override func enableEditing() {
        let relay = callbacks
        Task { @MainActor in relay.editing?(true) }
    }
}
