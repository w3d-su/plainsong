import { imageSourcePolicy } from "./image-policy";

export function rewriteImageSources(
  root: ParentNode,
  baseDir: string | null,
  allowRemoteImages: boolean,
  assetRootID = "",
): void {
  for (const image of root.querySelectorAll<HTMLImageElement>("img")) {
    const source = image.dataset.plainsongOriginalSrc ?? image.getAttribute("src");
    if (!source) continue;

    image.dataset.plainsongOriginalSrc = source;
    const policy = imageSourcePolicy(source, baseDir, allowRemoteImages, assetRootID);
    switch (policy.action) {
      case "keep":
        image.src = source;
        delete image.dataset.plainsongBlockedSrc;
        break;
      case "rewrite":
        image.src = policy.src;
        delete image.dataset.plainsongBlockedSrc;
        break;
      case "block":
        image.removeAttribute("src");
        image.dataset.plainsongBlockedSrc = source;
        break;
    }
  }
}
