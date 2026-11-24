// Mermaid output is inserted after the image policy and the MDX sanitizer have run, and
// `securityLevel: "strict"` keeps author HTML labels, `<img>` and CSS from `themeVariables`.
// This applies the preview's rules to that output before it enters the live document.

const removedElements = [
  "script", "img", "image", "feImage", "picture", "source", "video", "audio", "track",
  "iframe", "object", "embed", "form", "input", "button", "select", "textarea", "label",
  "link", "meta", "base", "animate", "set", "animateTransform", "animateMotion",
].join(",");

/** Classes and attributes the preview reads as its own state (`mermaid-dom.ts`, `index.ts`). */
const internalClasses = [
  "mermaid-rendered", "mermaid-pending", "mermaid-error", "mdx-error-banner", "preview-stale",
  "task-list-item", "contains-task-list",
];
const internalAttributes = new Set([
  "data-line", "data-line-end", "data-task-checkbox", "data-mermaid-source",
  "data-mermaid-ordinal", "data-mermaid-generation", "data-plainsong-original-src",
  "data-plainsong-blocked-src", "data-plainsong-language", "data-highlighted",
]);
const linkAttributes = new Set(["href", "xlink:href"]);

/** Parses Mermaid's SVG in an inert document and returns the nodes that may be inserted. */
export function sanitizedMermaidNodes(svg: string): Node[] {
  const inert = document.implementation.createHTMLDocument("");
  inert.body.innerHTML = svg;
  for (const element of inert.body.querySelectorAll(removedElements)) element.remove();
  for (const element of inert.body.querySelectorAll("*")) sanitizeElement(element);
  return Array.from(inert.body.childNodes);
}

function sanitizeElement(element: Element): void {
  if (element.localName === "style") {
    element.textContent = sanitizedMermaidCSS(element.textContent ?? "");
  }
  element.classList.remove(...internalClasses);
  for (const { name, value } of Array.from(element.attributes)) {
    const lowered = name.toLowerCase();
    if (
      lowered.startsWith("on") ||
      internalAttributes.has(lowered) ||
      (linkAttributes.has(lowered) && !isAllowedLink(element, value)) ||
      (lowered === "style" && sanitizedMermaidCSS(value) !== value) ||
      (lowered !== "style" && !linkAttributes.has(lowered) && hasExternalCSSURL(value))
    ) {
      element.removeAttribute(name);
    }
  }
}

/** `<use>` may only reference the diagram itself; links may go where preview links go. */
function isAllowedLink(element: Element, value: string): boolean {
  const target = value.trim();
  if (target.startsWith("#")) return true;
  return element.localName === "a" && /^https?:/i.test(target);
}

function hasExternalCSSURL(value: string): boolean {
  return sanitizedMermaidCSS(value) !== value;
}

/** Drops every CSS construct that loads a resource. `url(#marker)` stays: Mermaid's arrow
 * heads and gradients use it. Escapes go first so `\75rl(` cannot spell `url(`. */
export function sanitizedMermaidCSS(css: string): string {
  if (!/[\\@(]/.test(css)) return css;
  return css
    .replaceAll("\\", "")
    .replace(/@import\b[^;]*;?/gi, "")
    .replace(/@(?:font-face|namespace)\b[^{;]*(?:\{[^}]*\}|;)?/gi, "")
    .replace(/\burl\s*\(\s*(["']?)\s*(?!#)[^)]*\)/gi, "none")
    .replace(/(?:\b|-webkit-)(?:image-set|image|cross-fade|src)\s*\([^)]*\)/gi, "none");
}
