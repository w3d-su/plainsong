import { assetURLPath, workspaceRelativeAssetPath } from "./asset-path";

export type ImageSourcePolicy =
  | { action: "keep" }
  | { action: "rewrite"; src: string }
  | { action: "block"; reason: "empty" | "remote-disabled" | "unsupported-scheme" };

export function imageSourcePolicy(
  source: string,
  baseDir: string | null,
  allowRemoteImages: boolean,
): ImageSourcePolicy {
  const trimmed = source.trim();
  if (!trimmed) {
    return { action: "block", reason: "empty" };
  }

  if (isWorkspaceRelativeURL(trimmed)) {
    const assetPath = workspaceRelativeAssetPath(trimmed, baseDir);
    return { action: "rewrite", src: `asset://${assetURLPath(assetPath)}` };
  }

  const protocol = protocolForSource(trimmed);
  switch (protocol) {
    case "asset:":
    case "data:":
      return { action: "keep" };
    case "https:":
      return allowRemoteImages ? { action: "keep" } : { action: "block", reason: "remote-disabled" };
    default:
      return { action: "block", reason: "unsupported-scheme" };
  }
}

export function isWorkspaceRelativeURL(value: string): boolean {
  return !/^(?:[a-z][a-z0-9+.-]*:|#|\/)/iu.test(value);
}

function protocolForSource(source: string): string | null {
  try {
    return new URL(source).protocol.toLowerCase();
  } catch {
    return null;
  }
}
