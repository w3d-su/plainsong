import Foundation
import MarkdownCore

public enum PreviewBridge {
    public static let protocolVersion = 3
}

public enum BridgeMessageName: String, CaseIterable, Codable, Sendable {
    case ready
    case render
    case renderComplete
    case scrollToLine
    case previewScrolled
    case linkClicked
    case checkboxToggled
    case setTheme
}

public enum PreviewFileKind: String, Codable, Sendable {
    case md
    case mdx

    public init(_ fileKind: FileKind) {
        switch fileKind {
        case .markdown:
            self = .md
        case .mdx:
            self = .mdx
        }
    }
}

public struct ReadyPayload: Codable, Equatable, Sendable {
    public let protocolVersion: Int

    public init(protocolVersion: Int) {
        self.protocolVersion = protocolVersion
    }
}

public struct RenderPayload: Codable, Equatable, Sendable {
    public let version: Int
    public let fileKind: PreviewFileKind
    public let text: String
    public let baseDir: String?
    public let theme: String

    public init(
        version: Int,
        fileKind: PreviewFileKind,
        text: String,
        baseDir: String?,
        theme: String
    ) {
        self.version = version
        self.fileKind = fileKind
        self.text = text
        self.baseDir = baseDir
        self.theme = theme
    }

    public init(change: DocumentTextChange, theme: String, baseDir: String? = nil) {
        self.init(
            version: change.version,
            fileKind: PreviewFileKind(change.fileKind),
            text: change.text,
            baseDir: baseDir,
            theme: theme
        )
    }
}

public struct RenderCompletePayload: Codable, Equatable, Sendable {
    public let version: Int
    public let blockCount: Int

    public init(version: Int, blockCount: Int) {
        self.version = version
        self.blockCount = blockCount
    }
}

public struct ScrollToLinePayload: Codable, Equatable, Sendable {
    public let line: Int
    public let animated: Bool

    public init(line: Int, animated: Bool) {
        self.line = line
        self.animated = animated
    }
}

public struct PreviewScrolledPayload: Codable, Equatable, Sendable {
    public let topVisibleLine: Int

    public init(topVisibleLine: Int) {
        self.topVisibleLine = topVisibleLine
    }
}

public struct LinkClickedPayload: Codable, Equatable, Sendable {
    public let href: String

    public init(href: String) {
        self.href = href
    }
}

public struct CheckboxToggledPayload: Codable, Equatable, Sendable {
    public let line: Int
    public let checked: Bool
    public let version: Int

    public init(line: Int, checked: Bool, version: Int) {
        self.line = line
        self.checked = checked
        self.version = version
    }
}

public struct SetThemePayload: Codable, Equatable, Sendable {
    public let theme: String

    public init(theme: String) {
        self.theme = theme
    }
}

public enum BridgeMessage: Equatable, Sendable {
    case ready(ReadyPayload)
    case render(RenderPayload)
    case renderComplete(RenderCompletePayload)
    case scrollToLine(ScrollToLinePayload)
    case previewScrolled(PreviewScrolledPayload)
    case linkClicked(LinkClickedPayload)
    case checkboxToggled(CheckboxToggledPayload)
    case setTheme(SetThemePayload)

    public var name: BridgeMessageName {
        switch self {
        case .ready:
            .ready
        case .render:
            .render
        case .renderComplete:
            .renderComplete
        case .scrollToLine:
            .scrollToLine
        case .previewScrolled:
            .previewScrolled
        case .linkClicked:
            .linkClicked
        case .checkboxToggled:
            .checkboxToggled
        case .setTheme:
            .setTheme
        }
    }
}

extension BridgeMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case name
        case payload
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(BridgeMessageName.self, forKey: .name)

        switch name {
        case .ready:
            self = try .ready(container.decode(ReadyPayload.self, forKey: .payload))
        case .render:
            self = try .render(container.decode(RenderPayload.self, forKey: .payload))
        case .renderComplete:
            self = try .renderComplete(container.decode(RenderCompletePayload.self, forKey: .payload))
        case .scrollToLine:
            self = try .scrollToLine(container.decode(ScrollToLinePayload.self, forKey: .payload))
        case .previewScrolled:
            self = try .previewScrolled(container.decode(PreviewScrolledPayload.self, forKey: .payload))
        case .linkClicked:
            self = try .linkClicked(container.decode(LinkClickedPayload.self, forKey: .payload))
        case .checkboxToggled:
            self = try .checkboxToggled(container.decode(CheckboxToggledPayload.self, forKey: .payload))
        case .setTheme:
            self = try .setTheme(container.decode(SetThemePayload.self, forKey: .payload))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)

        switch self {
        case let .ready(payload):
            try container.encode(payload, forKey: .payload)
        case let .render(payload):
            try container.encode(payload, forKey: .payload)
        case let .renderComplete(payload):
            try container.encode(payload, forKey: .payload)
        case let .scrollToLine(payload):
            try container.encode(payload, forKey: .payload)
        case let .previewScrolled(payload):
            try container.encode(payload, forKey: .payload)
        case let .linkClicked(payload):
            try container.encode(payload, forKey: .payload)
        case let .checkboxToggled(payload):
            try container.encode(payload, forKey: .payload)
        case let .setTheme(payload):
            try container.encode(payload, forKey: .payload)
        }
    }
}
