import MarkdownCore
import WebKit

/// PreviewKit owns the WKWebView preview, the Swift↔JS bridge (`BridgeMessage.swift`,
/// from M2), and the `asset://` URL scheme handler (agent.md §7).
/// Keep the bridge in sync with `preview-src/src/index.ts` — bump `PROTOCOL_VERSION`
/// in both files in the same commit (agent.md §17 rule 5).
public enum PreviewKitInfo {
    public static let version = "0.1.0"
}
