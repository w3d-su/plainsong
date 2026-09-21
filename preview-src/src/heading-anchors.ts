import type { TreeNode } from "./mdx-placeholders";

const headingIDPrefix = "plainsong-heading-";

export function rehypeHeadingAnchors() {
  return (tree: TreeNode) => {
    const used = new Set<string>();
    function visit(node: TreeNode): void {
      if (node.type === "element" && /^h[1-6]$/u.test(node.tagName ?? "") && !node.properties?.id) {
        const base = headingSlug(textContent(node)) || "section";
        let slug = base;
        let suffix = 0;
        while (used.has(slug)) slug = `${base}-${++suffix}`;
        used.add(slug);
        node.properties ??= {};
        // Namespace generated IDs so heading text cannot clobber DOM/window properties.
        node.properties.id = headingIDPrefix + slug;
      }
      for (const child of node.children ?? []) visit(child);
    }
    visit(tree);
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
