import Carbon
import Foundation

extension EditorFindSyntheticShortcutInputSource {
    static func discoveredCapabilities() -> [EditorFindInputSourceCapabilities] {
        let original = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        return eligibleInputSourceCandidates(original: original)
            .map(\.capabilities)
    }

    static func currentInputSourceIdentifier() -> String? {
        let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        return inputSourceIdentifier(current)
    }

    static func eligibleCapabilities(
        from candidates: [EditorFindInputSourceCapabilities]
    ) -> [EditorFindInputSourceCapabilities] {
        orderedEligibleCandidates(from: candidates) { $0 }
            .map(\.capabilities)
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

    static func eligibleInputSourceCandidates(
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

    static func capabilities(
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

    static func inputSourceIdentifier(
        _ inputSource: TISInputSource
    ) -> String? {
        inputSourceStringProperty(inputSource, key: kTISPropertyInputSourceID)
    }
}

private extension EditorFindSyntheticShortcutInputSource {
    static func inputSourceStringProperty(
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

    static func inputSourceBooleanProperty(
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
