import Foundation

/// Opaque identity for the document currently rendered by an editor instance.
public struct EditorDocumentIdentity: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// A monotonic request to select an exact raw UTF-16 range in one document.
public struct EditorNavigationRequest: Identifiable, Equatable, Sendable {
    public let id: UInt64
    public let documentIdentity: EditorDocumentIdentity
    public let selection: NSRange

    public init(
        id: UInt64,
        documentIdentity: EditorDocumentIdentity,
        selection: NSRange
    ) {
        self.id = id
        self.documentIdentity = documentIdentity
        self.selection = selection
    }
}

struct EditorNavigationContext {
    let documentIdentity: EditorDocumentIdentity?
    let isDocumentTextInstalled: Bool
    let documentTextUTF16Length: Int
    let hasMarkedText: Bool
    let isAttached: Bool
}

enum EditorNavigationPendingReason: Equatable {
    case documentMismatch
    case markedText
    case documentTextNotInstalled
    case notAttached
}

enum EditorNavigationDecision: Equatable {
    case noRequest
    case pending(EditorNavigationPendingReason)
    case rejected(EditorNavigationRequest)
    case ready(EditorNavigationRequest)
}

/// Keeps request ordering and range validation independent from AppKit effects.
struct EditorNavigationStateMachine {
    private(set) var highestObservedRequestID: UInt64?
    private(set) var pendingRequest: EditorNavigationRequest?
    private(set) var lastHandledRequestID: UInt64?
    private(set) var lastRejectedRequestID: UInt64?

    mutating func observe(_ request: EditorNavigationRequest?) {
        guard let request else { return }
        if let highestObservedRequestID,
           request.id <= highestObservedRequestID
        {
            return
        }

        highestObservedRequestID = request.id
        pendingRequest = request
    }

    mutating func nextDecision(in context: EditorNavigationContext) -> EditorNavigationDecision {
        guard let request = pendingRequest else {
            return .noRequest
        }
        guard Self.isStructurallyValidExactRange(request.selection) else {
            pendingRequest = nil
            lastRejectedRequestID = request.id
            return .rejected(request)
        }
        guard request.documentIdentity == context.documentIdentity else {
            return .pending(.documentMismatch)
        }
        guard !context.hasMarkedText else {
            return .pending(.markedText)
        }
        guard context.isDocumentTextInstalled else {
            return .pending(.documentTextNotInstalled)
        }
        guard Self.isValidExactRange(
            request.selection,
            textUTF16Length: context.documentTextUTF16Length
        ) else {
            pendingRequest = nil
            lastRejectedRequestID = request.id
            return .rejected(request)
        }
        guard context.isAttached else {
            return .pending(.notAttached)
        }

        return .ready(request)
    }

    mutating func markHandled(_ request: EditorNavigationRequest) {
        guard pendingRequest == request else { return }
        pendingRequest = nil
        lastHandledRequestID = request.id
    }

    /// Uses subtraction after sign/bounds checks so malformed ranges never overflow.
    static func isValidExactRange(_ range: NSRange, textUTF16Length: Int) -> Bool {
        guard textUTF16Length >= 0,
              isStructurallyValidExactRange(range),
              range.location <= textUTF16Length
        else {
            return false
        }

        return range.length <= textUTF16Length - range.location
    }

    private static func isStructurallyValidExactRange(_ range: NSRange) -> Bool {
        guard range.location != NSNotFound,
              range.location >= 0,
              range.length >= 0
        else {
            return false
        }

        return range.length <= Int.max - range.location
    }
}

/// Executes the required navigation effects in their contract order.
@MainActor
struct EditorNavigationEffects {
    let applySelection: (NSRange) -> Bool
    let scrollRangeToVisible: (NSRange) -> Void
    let focusEditor: () -> Bool

    func perform(selection: NSRange) -> Bool {
        guard applySelection(selection) else { return false }
        scrollRangeToVisible(selection)
        return focusEditor()
    }
}
