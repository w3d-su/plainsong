import AppKit
import Carbon

/// Owns an app-active-only Carbon hot key for ⇧⌘F.
///
/// On the affected macOS runtime, physical ⇧⌘F is consumed between the session and
/// annotated-session event stages, before `NSEvent`, local monitors, `sendEvent`, or responder-chain
/// overrides can receive it. The evidence is consistent with pre-AppKit key-equivalent/global-hot-key
/// resolution; the exact owner is not exposed by the event pipeline. Carbon hot keys are resolved
/// before that loss, so register while Plainsong is active and unregister immediately on resign.
@MainActor
enum PlainsongWorkspaceSearchHotKey {
    /// `PLSN`, deliberately namespaced away from framework and system hot-key identifiers.
    private static let signature: OSType = 0x504C_534E
    private static let identifierValue: UInt32 = 1

    private static var eventHandler: EventHandlerRef?
    private static var hotKey: EventHotKeyRef?

    private static let eventHandlerCallback: EventHandlerUPP = { _, event, _ in
        guard let event else { return OSStatus(eventNotHandledErr) }

        var candidate = EventHotKeyID()
        var actualSize = 0
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            &actualSize,
            &candidate
        )
        guard status == noErr,
              actualSize == MemoryLayout<EventHotKeyID>.size,
              candidate.signature == signature,
              candidate.id == identifierValue
        else {
            return OSStatus(eventNotHandledErr)
        }

        guard Thread.isMainThread else {
            Task { @MainActor in
                handlePress()
            }
            return noErr
        }
        return MainActor.assumeIsolated {
            handlePress()
        }
    }

    static var isRegistered: Bool {
        hotKey != nil
    }

    static func activate() {
        installEventHandlerIfNeeded()
        guard eventHandler != nil, hotKey == nil else { return }

        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(PlainsongMenuKeyBinding.ansiFKeyCode),
            PlainsongMenuKeyBinding.carbonModifiers,
            identifier,
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyNoOptions),
            &reference
        )
        guard status == noErr, let reference else {
            assertionFailure("Failed to register app-active ⇧⌘F hot key: \(status)")
            return
        }
        hotKey = reference
    }

    static func deactivate() {
        guard let hotKey else { return }
        let status = UnregisterEventHotKey(hotKey)
        guard status == noErr else {
            assertionFailure("Failed to unregister app-active ⇧⌘F hot key: \(status)")
            return
        }
        self.hotKey = nil
    }

    static func tearDown() {
        deactivate()
        guard let eventHandler else { return }
        let status = RemoveEventHandler(eventHandler)
        guard status == noErr else {
            assertionFailure("Failed to remove ⇧⌘F Carbon event handler: \(status)")
            return
        }
        self.eventHandler = nil
    }

    static func matches(_ candidate: EventHotKeyID) -> Bool {
        candidate.signature == signature && candidate.id == identifierValue
    }

    @discardableResult
    static func handlePress() -> OSStatus {
        PlainsongWorkspaceSearchKeyAction.performIfAvailable()
        // The combination belongs to Plainsong while it is active. Consume even when workspace
        // search is unavailable so the conflicting system View-menu item cannot claim it.
        return noErr
    }

    private static var identifier: EventHotKeyID {
        EventHotKeyID(signature: signature, id: identifierValue)
    }

    private static func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var reference: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            eventHandlerCallback,
            1,
            &eventType,
            nil,
            &reference
        )
        guard status == noErr, let reference else {
            assertionFailure("Failed to install ⇧⌘F Carbon event handler: \(status)")
            return
        }
        eventHandler = reference
    }
}

/// Shared action used by the Carbon hot key (and tests).
enum PlainsongWorkspaceSearchKeyAction {
    /// - Returns: `true` when the workspace-search mode was toggled.
    @MainActor
    @discardableResult
    static func performIfAvailable() -> Bool {
        guard let appState = PlainsongAppServices.appState,
              appState.canUseWorkspaceSearch
        else {
            return false
        }
        appState.toggleWorkspaceSearch()
        return true
    }
}
