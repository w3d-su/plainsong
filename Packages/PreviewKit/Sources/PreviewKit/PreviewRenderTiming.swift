import Foundation

/// One render's time between being handed to JavaScript and its `renderComplete`, on the
/// `ProcessInfo.systemUptime` clock. It covers the bridge transfer, the unified pipeline,
/// highlighting and the DOM patch; Mermaid diagrams that settle later are outside it.
public struct PreviewRenderTiming: Sendable, Equatable {
    public let renderID: Int
    public let version: Int
    public let sentUptime: TimeInterval
    public let completedUptime: TimeInterval

    public init(renderID: Int, version: Int, sentUptime: TimeInterval, completedUptime: TimeInterval) {
        self.renderID = renderID
        self.version = version
        self.sentUptime = sentUptime
        self.completedUptime = completedUptime
    }

    public var duration: TimeInterval {
        completedUptime - sentUptime
    }
}
