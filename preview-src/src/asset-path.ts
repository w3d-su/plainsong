export function workspaceRelativeAssetPath(source: string, baseDir: string | null): string {
  const normalizedSource = source.replaceAll("\\", "/");
  const normalizedBaseDir = baseDir?.replace(/^\/+|\/+$/g, "") ?? "";
  const combinedPath = normalizedBaseDir ? `${normalizedBaseDir}/${normalizedSource}` : normalizedSource;

  return normalizeRelativePath(combinedPath);
}

export function assetURLPath(relativePath: string): string {
  return relativePath
    .replace(/%(?![0-9a-fA-F]{2})/g, "%25")
    .replaceAll(" ", "%20")
    .replaceAll("#", "%23")
    .replaceAll("?", "%3F");
}

function normalizeRelativePath(path: string): string {
  const segments: string[] = [];

  for (const segment of path.split("/")) {
    if (!segment || segment === ".") continue;

    if (segment === "..") {
      if (segments.length > 0 && segments[segments.length - 1] !== "..") {
        segments.pop();
      } else {
        segments.push(segment);
      }
      continue;
    }

    segments.push(segment);
  }

  return segments.join("/");
}
