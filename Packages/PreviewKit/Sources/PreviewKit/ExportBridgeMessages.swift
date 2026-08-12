import Foundation

public enum ExportHTMLPhase: String, Codable, Equatable, Sendable {
    case discovery
    case finalization
}

public enum ExportResourceKind: String, Codable, Equatable, Sendable {
    case image
    case font
}

public enum ExportResourceAction: String, Codable, Equatable, Sendable {
    case embed
    case omit
}

public struct ExportResourceDescriptor: Codable, Equatable, Sendable {
    public let resourceID: String
    public let kind: ExportResourceKind
    public let src: String

    public init(resourceID: String, kind: ExportResourceKind, src: String) {
        self.resourceID = resourceID
        self.kind = kind
        self.src = src
    }
}

public struct ExportResourceOutcome: Codable, Equatable, Sendable {
    public let resourceID: String
    public let kind: ExportResourceKind
    public let action: ExportResourceAction
    public let dataURI: String?
    public let reason: String?

    public init(
        resourceID: String,
        kind: ExportResourceKind,
        action: ExportResourceAction,
        dataURI: String? = nil,
        reason: String? = nil
    ) {
        self.resourceID = resourceID
        self.kind = kind
        self.action = action
        self.dataURI = dataURI
        self.reason = reason
    }

    public static func omit(
        _ resource: ExportResourceDescriptor,
        reason: String = "unresolved-in-static-skeleton"
    ) -> ExportResourceOutcome {
        ExportResourceOutcome(
            resourceID: resource.resourceID,
            kind: resource.kind,
            action: .omit,
            reason: reason
        )
    }
}

public struct ExportHTMLPayload: Codable, Equatable, Sendable {
    public let exportID: Int
    public let renderID: Int
    public let phase: ExportHTMLPhase
    public let resourceOutcomes: [ExportResourceOutcome]

    public init(
        exportID: Int,
        renderID: Int,
        phase: ExportHTMLPhase,
        resourceOutcomes: [ExportResourceOutcome] = []
    ) {
        self.exportID = exportID
        self.renderID = renderID
        self.phase = phase
        self.resourceOutcomes = resourceOutcomes
    }
}

public enum ExportHTMLResultState: Equatable, Sendable {
    case resourcesNeeded(resources: [ExportResourceDescriptor])
    case ready(html: String)
    case failed(reason: String)
}

public struct ExportHTMLResultPayload: Codable, Equatable, Sendable {
    public let exportID: Int
    public let renderID: Int
    public let state: ExportHTMLResultState

    public init(exportID: Int, renderID: Int, state: ExportHTMLResultState) {
        self.exportID = exportID
        self.renderID = renderID
        self.state = state
    }
}

public enum PreviewHTMLExportResult: Equatable, Sendable {
    case ready(html: String, exportID: Int, renderID: Int)
    case failed(reason: String, exportID: Int, renderID: Int)
}

extension ExportHTMLResultState: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case resources
        case html
        case reason
    }

    private enum Kind: String, Codable {
        case resourcesNeeded
        case ready
        case failed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .resourcesNeeded:
            self = try .resourcesNeeded(resources: container.decode(
                [ExportResourceDescriptor].self,
                forKey: .resources
            ))
        case .ready:
            self = try .ready(html: container.decode(String.self, forKey: .html))
        case .failed:
            self = try .failed(reason: container.decode(String.self, forKey: .reason))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .resourcesNeeded(resources):
            try container.encode(Kind.resourcesNeeded, forKey: .kind)
            try container.encode(resources, forKey: .resources)
        case let .ready(html):
            try container.encode(Kind.ready, forKey: .kind)
            try container.encode(html, forKey: .html)
        case let .failed(reason):
            try container.encode(Kind.failed, forKey: .kind)
            try container.encode(reason, forKey: .reason)
        }
    }
}
