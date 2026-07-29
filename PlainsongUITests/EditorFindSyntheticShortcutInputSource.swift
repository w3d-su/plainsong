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
enum EditorFindSyntheticShortcutInputSource {
    enum InputSourceError: Error, CustomStringConvertible {
        case noEligibleInputSource
        case couldNotUseEligibleInputSources([String])
        case couldNotRestoreInputSource(identifier: String, status: OSStatus)
        case restoredSourceDidNotBecomeCurrent(String)

        var description: String {
            switch self {
            case .noEligibleInputSource:
                "No enabled, select-capable ASCII input source is available"
            case let .couldNotUseEligibleInputSources(failures):
                "Eligible ASCII input sources could not be selected and read back: "
                    + failures.joined(separator: "; ")
            case let .couldNotRestoreInputSource(identifier, status):
                "Could not restore input source \(identifier): OSStatus \(status)"
            case let .restoredSourceDidNotBecomeCurrent(identifier):
                "Restored input source did not become current: \(identifier)"
            }
        }
    }

    static func withASCIICapableInputSource(
        _ body: () -> Void
    ) throws -> String {
        let original = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let candidates = eligibleInputSourceCandidates(original: original)
        guard !candidates.isEmpty else {
            throw InputSourceError.noEligibleInputSource
        }

        var selectionFailures: [String] = []
        for candidate in candidates {
            let status = TISSelectInputSource(candidate.value)
            guard status == noErr else {
                selectionFailures.append(
                    "\(candidate.capabilities.identifier): OSStatus \(status)"
                )
                continue
            }
            guard currentInputSourceMatches(candidate.value) else {
                try restoreExactInputSource(original)
                selectionFailures.append(
                    "\(candidate.capabilities.identifier): current-source readback mismatch"
                )
                continue
            }

            body()
            try restoreExactInputSource(original)
            return candidate.capabilities.identifier
        }

        throw InputSourceError.couldNotUseEligibleInputSources(
            selectionFailures
        )
    }

    static func restoreExactInputSource(_ inputSource: TISInputSource) throws {
        let identifier = inputSourceIdentifier(inputSource) ?? "<unknown>"
        let status = TISSelectInputSource(inputSource)
        guard status == noErr else {
            throw InputSourceError.couldNotRestoreInputSource(
                identifier: identifier,
                status: status
            )
        }
        guard currentInputSourceMatches(inputSource) else {
            throw InputSourceError.restoredSourceDidNotBecomeCurrent(identifier)
        }
    }

    static func discoveredCapabilities() -> [EditorFindInputSourceCapabilities] {
        let original = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        return eligibleInputSourceCandidates(original: original)
            .map(\.capabilities)
    }

    static func eligibleCapabilities(
        from candidates: [EditorFindInputSourceCapabilities]
    ) -> [EditorFindInputSourceCapabilities] {
        orderedEligibleCandidates(from: candidates) { $0 }
            .map(\.capabilities)
    }

    struct EligibleCandidate<Value> {
        let value: Value
        let capabilities: EditorFindInputSourceCapabilities
    }

    static func orderedEligibleCandidates<Value>(
        from candidates: [Value],
        capabilities: (Value) -> EditorFindInputSourceCapabilities
    ) -> [EligibleCandidate<Value>] {
        var seenIdentifiers = Set<String>()
        return candidates.compactMap { candidate in
            let candidateCapabilities = capabilities(candidate)
            guard candidateCapabilities.isEligibleForSyntheticTextShortcut,
                  seenIdentifiers.insert(
                      candidateCapabilities.identifier
                  ).inserted
            else {
                return nil
            }
            return EligibleCandidate(
                value: candidate,
                capabilities: candidateCapabilities
            )
        }
    }

    private static func eligibleInputSourceCandidates(
        original: TISInputSource
    ) -> [EligibleCandidate<TISInputSource>] {
        let recentASCII =
            TISCopyCurrentASCIICapableKeyboardInputSource().takeRetainedValue()
        let asciiSources =
            TISCreateASCIICapableInputSourceList().takeRetainedValue() as NSArray
        var candidates = [original, recentASCII]
        candidates.append(contentsOf: asciiSources.map { source in
            // swiftlint:disable:next force_cast
            source as! TISInputSource
        })

        return orderedEligibleCandidates(
            from: candidates,
            capabilities: capabilities(for:)
        )
    }

    private static func capabilities(
        for inputSource: TISInputSource
    ) -> EditorFindInputSourceCapabilities {
        EditorFindInputSourceCapabilities(
            identifier: inputSourceIdentifier(inputSource) ?? "",
            isKeyboardInputSource: inputSourceStringProperty(
                inputSource,
                key: kTISPropertyInputSourceCategory
            ) == kTISCategoryKeyboardInputSource as String,
            isEnabled: inputSourceBooleanProperty(
                inputSource,
                key: kTISPropertyInputSourceIsEnabled
            ),
            isSelectCapable: inputSourceBooleanProperty(
                inputSource,
                key: kTISPropertyInputSourceIsSelectCapable
            ),
            isASCIICapable: inputSourceBooleanProperty(
                inputSource,
                key: kTISPropertyInputSourceIsASCIICapable
            )
        )
    }

    private static func currentInputSourceMatches(
        _ expected: TISInputSource
    ) -> Bool {
        let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        if let expectedIdentifier = inputSourceIdentifier(expected),
           let currentIdentifier = inputSourceIdentifier(current)
        {
            return expectedIdentifier == currentIdentifier
        }
        return CFEqual(current, expected)
    }

    private static func inputSourceIdentifier(
        _ inputSource: TISInputSource
    ) -> String? {
        inputSourceStringProperty(inputSource, key: kTISPropertyInputSourceID)
    }

    private static func inputSourceStringProperty(
        _ inputSource: TISInputSource,
        key: CFString
    ) -> String? {
        guard let rawValue = TISGetInputSourceProperty(inputSource, key) else {
            return nil
        }
        return Unmanaged<CFString>
            .fromOpaque(rawValue)
            .takeUnretainedValue() as String
    }

    private static func inputSourceBooleanProperty(
        _ inputSource: TISInputSource,
        key: CFString
    ) -> Bool {
        guard let rawValue = TISGetInputSourceProperty(inputSource, key) else {
            return false
        }
        return CFBooleanGetValue(
            Unmanaged<CFBoolean>.fromOpaque(rawValue).takeUnretainedValue()
        )
    }
}
