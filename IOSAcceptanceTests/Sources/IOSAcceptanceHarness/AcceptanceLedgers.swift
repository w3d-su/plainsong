import Foundation
import WorkspaceCore

public enum AcceptanceStatus: String, Equatable, Sendable {
    case pass
    case fail
    case open
    case blocked
}

public struct ProductGate: Equatable, Sendable {
    public let id: String
    public let status: AcceptanceStatus
    public let evidence: String

    public init(id: String, status: AcceptanceStatus, evidence: String) {
        self.id = id
        self.status = status
        self.evidence = evidence
    }
}

public enum ProductGateLedger {
    public static let gates: [ProductGate] = [
        ProductGate(
            id: "launch-reopen",
            status: .blocked,
            evidence: "Hosted launch target is not wired. DEBUG fixture injection stays disabled."
        ),
        ProductGate(id: "iphone-layout", status: .open, evidence: "No hosted layout run on this head."),
        ProductGate(id: "ipad-regular", status: .open, evidence: "No hosted regular-width run on this head."),
        ProductGate(id: "ipad-compact", status: .open, evidence: "No hosted compact-width run on this head."),
        ProductGate(
            id: "selection-across-layout",
            status: .open,
            evidence: "Selection, undo, and document identity across focus changes are not hosted."
        ),
        ProductGate(
            id: "product-stale-save",
            status: .open,
            evidence: "Component rebase checks are not a UIDocument save queue."
        ),
        ProductGate(
            id: "late-callback",
            status: .open,
            evidence: "No product file-coordination callback on this head."
        ),
        ProductGate(
            id: "dirty-external-conflict",
            status: .open,
            evidence: "No product conflict banner or recovery file on this head."
        ),
        ProductGate(id: "files-provider", status: .open, evidence: "No real Files or iCloud provider is installed."),
        ProductGate(id: "image-rollback", status: .open, evidence: "Product image insertion is not composed."),
        ProductGate(
            id: "preview-bundle-render",
            status: .open,
            evidence: "Committed bundle bytes are hashed. WebKit ready remains unresolved."
        ),
        ProductGate(id: "voiceover", status: .open, evidence: "No owner VoiceOver pass."),
        ProductGate(id: "hardware-keyboard", status: .open, evidence: "No owner hardware-keyboard pass."),
        ProductGate(id: "ime-device", status: .open, evidence: "No owner Zhuyin or Pinyin pass."),
        ProductGate(id: "performance-input-to-screen", status: .open, evidence: "No visible-presentation samples."),
        ProductGate(id: "performance-visible-highlight", status: .open, evidence: "No visible-highlight samples."),
        ProductGate(id: "performance-render-completion", status: .open, evidence: "No render-completion samples."),
        ProductGate(id: "owner-install", status: .open, evidence: "No owner-signed install."),
        ProductGate(
            id: "debug-seam",
            status: .blocked,
            evidence: "The acceptance seam is hard-disabled. Lane 13 owns any future DEBUG injection."
        ),
    ]
}

public enum AcceptanceDebugSeam {
    public static let isEnabled = false

    public static func releaseCanEnable() -> Bool {
        false
    }
}

public enum WorkspaceAuthorityCheck {
    public static func sameGrant(_ lhs: IOSFileLocation, _ rhs: IOSFileLocation) -> Bool {
        lhs.workspaceID == rhs.workspaceID && lhs.accessGeneration == rhs.accessGeneration
    }

    public static func singleFileAllows(grantedRelativePath: String, requested: String) -> Bool {
        grantedRelativePath == requested && WorkspaceRelativePath(spelling: requested) != nil
    }
}

public enum PerformanceMeasureKind: String, Equatable, Sendable {
    case inputToScreen
    case visibleHighlight
    case renderCompletion
    case textDidChangeOnly
}

public struct PerformanceSample: Equatable, Sendable {
    public var kind: PerformanceMeasureKind
    public var milliseconds: Double
    public var fixture: String
    public var includesVisiblePresentation: Bool
    public var thermalState: String?
    public var lowPowerMode: Bool?
    public var operatingSystem: String?
    public var configuration: String?
    public var environment: String

    public init(
        kind: PerformanceMeasureKind,
        milliseconds: Double,
        fixture: String,
        includesVisiblePresentation: Bool,
        thermalState: String?,
        lowPowerMode: Bool?,
        operatingSystem: String?,
        configuration: String?,
        environment: String
    ) {
        self.kind = kind
        self.milliseconds = milliseconds
        self.fixture = fixture
        self.includesVisiblePresentation = includesVisiblePresentation
        self.thermalState = thermalState
        self.lowPowerMode = lowPowerMode
        self.operatingSystem = operatingSystem
        self.configuration = configuration
        self.environment = environment
    }
}

public enum PerformanceVerdict: Equatable, Sendable {
    case open(String)
    case diagnostic(count: Int)
}

public enum PerformanceSampleLedger {
    public static let minimumSamples = 60

    public static func verdict(
        samples: [PerformanceSample],
        kind: PerformanceMeasureKind
    ) -> PerformanceVerdict {
        guard kind != .textDidChangeOnly else {
            return .open("textDidChange duration is not input-to-screen")
        }
        let visible = samples.filter {
            $0.kind == kind && $0.includesVisiblePresentation
        }
        guard visible.count >= minimumSamples else {
            return .open("fewer than 60 visible-presentation samples")
        }
        let contextIsComplete = visible.allSatisfy {
            $0.thermalState != nil && $0.lowPowerMode != nil && $0.operatingSystem != nil
                && $0.configuration != nil
        }
        guard contextIsComplete else {
            return .open("missing thermal, power, OS, or configuration")
        }
        return .diagnostic(count: visible.count)
    }
}

public enum AcceptanceRepository {
    public static func root(startingAt file: URL) -> URL? {
        var url = file.deletingLastPathComponent()
        for _ in 0 ..< 8 {
            let agent = url.appendingPathComponent("agent.md")
            let fixture = url.appendingPathComponent("Fixtures/kitchen-sink.md")
            if FileManager.default.fileExists(atPath: agent.path),
               FileManager.default.fileExists(atPath: fixture.path)
            {
                return url
            }
            url.deleteLastPathComponent()
        }
        return nil
    }
}
