import { assetURLPath, workspaceRelativeAssetPath } from "./asset-path";

export type ImageSourcePolicy =
  | { action: "keep" }
  | { action: "rewrite"; src: string }
  | {
      action: "block";
      reason: "empty" | "remote-disabled" | "unsupported-data-image" | "unsupported-scheme";
    };

const allowedDataImageMediaTypes = new Set([
  "image/gif",
  "image/jpeg",
  "image/png",
  "image/webp",
]);

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
      return { action: "keep" };
    case "data:":
      return allowedDataImageMediaTypes.has(dataURLMediaType(trimmed) ?? "")
        ? { action: "keep" }
        : { action: "block", reason: "unsupported-data-image" };
    case "https:":
      return allowRemoteImages ? { action: "keep" } : { action: "block", reason: "remote-disabled" };
    default:
      return { action: "block", reason: "unsupported-scheme" };
  }
}

function dataURLMediaType(source: string): string | null {
  const commaIndex = source.indexOf(",");
  if (commaIndex === -1) return null;

  const metadata = source.slice("data:".length, commaIndex).trim().toLowerCase();
  const mediaType = metadata.split(";")[0];
  return mediaType || null;
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
