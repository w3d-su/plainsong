/**
 * BlogEditor preview pipeline entry point.
 *
 * M2 implements here (agent.md §7): unified/remark render pipelines (md + mdx),
 * morphdom DOM patching, scroll sync, and the JS side of the bridge protocol.
 *
 * Bridge protocol (agent.md §7.3): keep in sync with
 * Packages/PreviewKit/.../BridgeMessage.swift — bump PROTOCOL_VERSION in both
 * files in the same commit.
 */
export const PROTOCOL_VERSION = 1;
