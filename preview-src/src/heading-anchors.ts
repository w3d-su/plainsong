import type { VFile } from "vfile";
import type { TreeNode } from "./mdx-placeholders";
import { holeMarker, type SegmentHoleOptions } from "./segment-holes";

export const headingIDPrefix = "plainsong-heading-";

export interface HeadingSlugFileData extends Record<string, unknown> {
  /** Segment mode: base slugs of the generated heading IDs, in document order. */
  headingSlugs?: string[];
}

/** Hands out unique slugs in document order; a repeated base gets `-1`, `-2`, …. */
export class HeadingSlugAllocator {
  private readonly used = new Set<string>();

  next(base: string): string {
    let slug = base;
    let suffix = 0;
    while (this.used.has(slug)) slug = `${base}-${++suffix}`;
    this.used.add(slug);
    return slug;
  }
}

export function rehypeHeadingAnchors(options?: SegmentHoleOptions) {
  return (tree: TreeNode, file: VFile) => {
    const slugs = new HeadingSlugAllocator();
    const segmentSlugs: string[] = [];
    function visit(node: TreeNode): void {
      if (node.type === "element" && /^h[1-6]$/u.test(node.tagName ?? "") && !node.properties?.id) {
        const base = headingSlug(textContent(node)) || "section";
        node.properties ??= {};
        if (options?.holes) {
          // Deduplication depends on every earlier heading; assembly allocates it.
          node.properties.id = holeMarker("H", segmentSlugs.length);
          segmentSlugs.push(base);
        } else {
          // Namespace generated IDs so heading text cannot clobber DOM/window properties.
          node.properties.id = headingIDPrefix + slugs.next(base);
        }
      }
      for (const child of node.children ?? []) visit(child);
    }
    visit(tree);
    if (options?.holes) (file.data as HeadingSlugFileData).headingSlugs = segmentSlugs;
  };
}

function textContent(node: TreeNode): string {
  return node.type === "text" ? node.value ?? "" : (node.children ?? []).map(textContent).join("");
}

function headingSlug(text: string): string {
  return text.toLowerCase().replace(/[^\p{L}\p{N}\p{M}\s_-]/gu, "")
    .replace(/[\s_-]+/gu, "-").replace(/^-+|-+$/gu, "");
}

/** Hash links stay entirely in the displayed preview, including missing/malformed targets. */
export function scrollPreviewAnchor(root: HTMLElement, href: string): boolean {
  if (!href.startsWith("#")) return false;
  let anchor: string;
  try {
    anchor = decodeURIComponent(href.slice(1));
  } catch {
    return true;
  }
  if (!anchor) {
    window.scrollTo({ top: 0, behavior: "auto" });
    return true;
  }
  const target = [anchor, headingIDPrefix + anchor, "user-content-" + anchor]
    .map((id) => root.ownerDocument.getElementById(id))
    .find((element) => element && root.contains(element));
  if (target) target.scrollIntoView({ block: "start", behavior: "auto" });
  return true;
}
