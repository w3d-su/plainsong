import Carbon
import Foundation

struct EditorFindInputSourceCapabilities: Equatable {
    let identifier: String
    let isKeyboardInputSource: Bool
    let isEnabled: Bool
    let isSelectCapable: Bool
    let isASCIICapable: Bool

    var isEligibleForSyntheticTextShortcut: Bool {
        !identifier.isEmpty
            && isKeyboardInputSource
            && isEnabled
            && isSelectCapable
            && isASCIICapable
    }
}

/// Textual `XCUIElement.typeKey` input is interpreted through the selected input source.
///
/// This helper makes only the synthetic textual shortcut deterministic. It never enables an
/// input source and it does not turn XCUITest injection into physical-keyboard evidence.
@MainActor
final class EditorFindSyntheticShortcutInputSource {
    enum RestorationDecision: Equatable {
        case readbackUnavailable
        case alreadyOriginal
        case restoreOriginal
        case preserveExternalChange
    }

    enum RestorationOutcome: Equatable {
        case notNeeded
        case alreadyOriginal
        case restored
        case externalChangePreserved(String)
    }

    enum InputSourceError: Error, CustomStringConvertible {
        case noEligibleInputSource
        case couldNotUseEligibleInputSources([String])
        case currentInputSourceIdentifierUnavailable
        case currentSourceChangedBeforeSelection(String)
        case currentSourceChangedDuringShortcut(String)
        case couldNotRestoreInputSource(identifier: String, status: OSStatus)
        case restoredSourceDidNotBecomeCurrent(String)

        var description: String {
            switch self {
            case .noEligibleInputSource:
                "No enabled, select-capable ASCII input source is available"
            case let .couldNotUseEligibleInputSources(failures):
                "Eligible ASCII input sources could not be selected and read back: "
                    + failures.joined(separator: "; ")
            case .currentInputSourceIdentifierUnavailable:
                "The current input source identifier could not be read back"
            case let .currentSourceChangedBeforeSelection(identifier):
                "The current input source changed externally before selection: "
                    + identifier
            case let .currentSourceChangedDuringShortcut(identifier):
                "The current input source changed externally during the shortcut: "
                    + identifier
            case let .couldNotRestoreInputSource(identifier, status):
                "Could not restore input source \(identifier): OSStatus \(status)"
            case let .restoredSourceDidNotBecomeCurrent(identifier):
                "Restored input source did not become current: \(identifier)"
            }
        }
    }

    struct EligibleCandidate<Value> {
        let value: Value
        let capabilities: EditorFindInputSourceCapabilities
    }

    fileprivate struct SelectionLease {
        let original: TISInputSource
        let originalIdentifier: String
        let selectedIdentifier: String
    }

    fileprivate enum CandidateUseResult {
        case used(String)
        case selectionFailed(String)
    }

    typealias CurrentIdentifierReader = () -> String?
    typealias Selector = (TISInputSource) -> OSStatus

    private let currentIdentifierReader: CurrentIdentifierReader
    private let selector: Selector
    private var pendingSelectionLease: SelectionLease?

    init(
        currentIdentifierReader: @escaping CurrentIdentifierReader = {
            EditorFindSyntheticShortcutInputSource
                .currentInputSourceIdentifier()
        },
        selector: @escaping Selector = { TISSelectInputSource($0) }
    ) {
        self.currentIdentifierReader = currentIdentifierReader
        self.selector = selector
    }

    var hasPendingRestoration: Bool {
        pendingSelectionLease != nil
    }

    func withASCIICapableInputSource(
        _ body: () -> Void
    ) throws -> String {
        if pendingSelectionLease != nil {
            _ = try restorePendingSelectionIfOwned()
        }

        let original = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let originalIdentifier = Self.inputSourceIdentifier(original) else {
            throw InputSourceError.currentInputSourceIdentifierUnavailable
        }
        let candidates = Self.eligibleInputSourceCandidates(original: original)
        guard !candidates.isEmpty else {
            throw InputSourceError.noEligibleInputSource
        }
        return try useFirstEligibleCandidate(
            candidates,
            original: original,
            originalIdentifier: originalIdentifier,
            body: body
        )
    }

    /// Restores only while the selected source is still the one this helper installed.
    ///
    /// Selection or readback failure keeps the lease for teardown retry. If another actor
    /// selected an identified third source, its change wins and the lease is retired.
    func restorePendingSelectionIfOwned() throws -> RestorationOutcome {
        guard let lease = pendingSelectionLease else {
            return .notNeeded
        }
        let currentIdentifier = currentIdentifierReader()
        switch Self.restorationDecision(
            originalIdentifier: lease.originalIdentifier,
            selectedIdentifier: lease.selectedIdentifier,
            currentIdentifier: currentIdentifier
        ) {
        case .readbackUnavailable:
            throw InputSourceError.currentInputSourceIdentifierUnavailable
        case .alreadyOriginal:
            pendingSelectionLease = nil
            return .alreadyOriginal
        case .preserveExternalChange:
            pendingSelectionLease = nil
            return .externalChangePreserved(currentIdentifier ?? "")
        case .restoreOriginal:
            return try restoreOriginalSource(for: lease)
        }
    }

    func installPendingSelectionLeaseForTesting(
        originalIdentifier: String,
        selectedIdentifier: String
    ) {
        pendingSelectionLease = SelectionLease(
            original: TISCopyCurrentKeyboardInputSource().takeRetainedValue(),
            originalIdentifier: originalIdentifier,
            selectedIdentifier: selectedIdentifier
        )
    }
}

private extension EditorFindSyntheticShortcutInputSource {
    func useFirstEligibleCandidate(
        _ candidates: [EligibleCandidate<TISInputSource>],
        original: TISInputSource,
        originalIdentifier: String,
        body: () -> Void
    ) throws -> String {
        var selectionFailures: [String] = []
        for candidate in candidates {
            switch try useCandidate(
                candidate,
                original: original,
                originalIdentifier: originalIdentifier,
                body: body
            ) {
            case let .used(identifier):
                return identifier
            case let .selectionFailed(failure):
                selectionFailures.append(failure)
            }
        }
        throw InputSourceError.couldNotUseEligibleInputSources(
            selectionFailures
        )
    }

    func useCandidate(
        _ candidate: EligibleCandidate<TISInputSource>,
        original: TISInputSource,
        originalIdentifier: String,
        body: () -> Void
    ) throws -> CandidateUseResult {
        let selectedIdentifier = candidate.capabilities.identifier
        let currentIdentifier = try readableCurrentIdentifier()
        guard currentIdentifier == originalIdentifier else {
            throw InputSourceError.currentSourceChangedBeforeSelection(
                currentIdentifier
            )
        }
        if selectedIdentifier == originalIdentifier {
            return try useCurrentCandidate(
                candidate,
                originalIdentifier: originalIdentifier,
                body: body
            )
        }
        return try selectCandidate(
            candidate,
            original: original,
            originalIdentifier: originalIdentifier,
            body: body
        )
    }

    func useCurrentCandidate(
        _ candidate: EligibleCandidate<TISInputSource>,
        originalIdentifier: String,
        body: () -> Void
    ) throws -> CandidateUseResult {
        let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let currentCapabilities = Self.capabilities(for: current)
        guard currentCapabilities.identifier == originalIdentifier else {
            throw InputSourceError.currentSourceChangedBeforeSelection(
                currentCapabilities.identifier
            )
        }
        guard currentCapabilities.isEligibleForSyntheticTextShortcut else {
            return .selectionFailed(
                "\(originalIdentifier): current source is no longer eligible"
            )
        }
        body()
        let finalIdentifier = try readableCurrentIdentifier()
        guard finalIdentifier == originalIdentifier else {
            throw InputSourceError.currentSourceChangedDuringShortcut(
                finalIdentifier
            )
        }
        return .used(candidate.capabilities.identifier)
    }

    func selectCandidate(
        _ candidate: EligibleCandidate<TISInputSource>,
        original: TISInputSource,
        originalIdentifier: String,
        body: () -> Void
    ) throws -> CandidateUseResult {
        let selectedIdentifier = candidate.capabilities.identifier
        let refreshedCapabilities = Self.capabilities(for: candidate.value)
        guard refreshedCapabilities.identifier == selectedIdentifier,
              refreshedCapabilities.isEligibleForSyntheticTextShortcut
        else {
            return .selectionFailed(
                "\(selectedIdentifier): source is no longer eligible"
            )
        }
        let boundaryIdentifier = try readableCurrentIdentifier()
        guard boundaryIdentifier == originalIdentifier else {
            throw InputSourceError.currentSourceChangedBeforeSelection(
                boundaryIdentifier
            )
        }
        let status = selector(candidate.value)
        guard status == noErr else {
            return .selectionFailed(
                "\(selectedIdentifier): OSStatus \(status)"
            )
        }
        pendingSelectionLease = SelectionLease(
            original: original,
            originalIdentifier: originalIdentifier,
            selectedIdentifier: selectedIdentifier
        )
        let selectedReadback = try readableCurrentIdentifier()
        guard selectedReadback == selectedIdentifier else {
            let outcome = try restorePendingSelectionIfOwned()
            if case .externalChangePreserved = outcome {
                throw InputSourceError.currentSourceChangedBeforeSelection(
                    selectedReadback
                )
            }
            return .selectionFailed(
                "\(selectedIdentifier): current-source readback mismatch"
            )
        }

        body()
        let restoration = try restorePendingSelectionIfOwned()
        if case let .externalChangePreserved(identifier) = restoration {
            throw InputSourceError.currentSourceChangedDuringShortcut(
                identifier
            )
        }
        return .used(selectedIdentifier)
    }

    func restoreOriginalSource(
        for lease: SelectionLease
    ) throws -> RestorationOutcome {
        let boundaryIdentifier = currentIdentifierReader()
        switch Self.restorationDecision(
            originalIdentifier: lease.originalIdentifier,
            selectedIdentifier: lease.selectedIdentifier,
            currentIdentifier: boundaryIdentifier
        ) {
        case .readbackUnavailable:
            throw InputSourceError.currentInputSourceIdentifierUnavailable
        case .alreadyOriginal:
            pendingSelectionLease = nil
            return .alreadyOriginal
        case .preserveExternalChange:
            pendingSelectionLease = nil
            return .externalChangePreserved(boundaryIdentifier ?? "")
        case .restoreOriginal:
            break
        }
        let status = selector(lease.original)
        guard status == noErr else {
            throw InputSourceError.couldNotRestoreInputSource(
                identifier: lease.originalIdentifier,
                status: status
            )
        }
        guard let restoredIdentifier = currentIdentifierReader() else {
            throw InputSourceError.currentInputSourceIdentifierUnavailable
        }
        guard restoredIdentifier == lease.originalIdentifier else {
            throw InputSourceError.restoredSourceDidNotBecomeCurrent(
                lease.originalIdentifier
            )
        }
        pendingSelectionLease = nil
        return .restored
    }

    func readableCurrentIdentifier() throws -> String {
        guard let identifier = currentIdentifierReader() else {
            throw InputSourceError.currentInputSourceIdentifierUnavailable
        }
        return identifier
    }
}

extension EditorFindSyntheticShortcutInputSource {
    static func restorationDecision(
        originalIdentifier: String,
        selectedIdentifier: String,
        currentIdentifier: String?
    ) -> RestorationDecision {
        guard let currentIdentifier else {
            return .readbackUnavailable
        }
        if currentIdentifier == originalIdentifier {
            return .alreadyOriginal
        }
        if currentIdentifier == selectedIdentifier {
            return .restoreOriginal
        }
        return .preserveExternalChange
    }
}
