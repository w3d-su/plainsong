import type { ExportResourceDescriptor } from "./bridge";
import { rewriteCSSURLs, sanitizeCSSURLs } from "./export-css-urls";
import { EXPORT_IMAGE_PLACEHOLDER_LABEL } from "./export-html-limits";
import {
  isStrictFontDataURI,
  isStrictImageDataURI,
  type ResolvedResourceOutcome,
} from "./export-html-outcomes";

export const EXPORT_IMAGE_SIZE_LIMIT_REASON = "Export image size limit";

const generatedSVGSelector = ".katex, .mermaid-rendered";
const svgNamespace = "http://www.w3.org/2000/svg";
const removedURLAttributes = new Set([
  "action",
  "archive",
  "background",
  "cite",
  "codebase",
  "dynsrc",
  "formaction",
  "icon",
  "longdesc",
  "lowsrc",
  "manifest",
  "ping",
  "poster",
  "srcset",
  "usemap",
  "xml:base",
]);
// SVG presentation attributes parse as CSS values, so url() in them is a CSS URL sink.
const cssValuedSVGAttributes = new Set([
  "clip-path",
  "cursor",
  "fill",
  "filter",
  "marker-end",
  "marker-mid",
  "marker-start",
  "mask",
  "stroke",
]);

export function utf8ByteLength(value: string): number {
  return new TextEncoder().encode(value).length;
}

/** Numbers font descriptors once across every CSS source so resource IDs never collide. */
export function collectFontResources(...cssTexts: string[]): ExportResourceDescriptor[] {
  const seen = new Set<string>();
  const resources: ExportResourceDescriptor[] = [];
  for (const css of cssTexts) {
    rewriteCSSURLs(css, (value, raw) => {
      const src = value?.trim() ?? "";
      if (src && !src.startsWith("#") && !/^data:/iu.test(src) && !seen.has(src)) {
        seen.add(src);
        resources.push({ resourceID: `font-${resources.length}`, kind: "font", src });
      }
      return raw;
    });
  }
  return resources;
}

export function embedFontSources(
  css: string,
  descriptors: readonly ExportResourceDescriptor[],
  outcomes: ReadonlyMap<string, ResolvedResourceOutcome>,
): { css: string; allowedFontDataURIs: Set<string> } {
  const embedded = new Map<string, string>();
  for (const descriptor of descriptors) {
    if (descriptor.kind !== "font") continue;
    const outcome = outcomes.get(descriptor.resourceID);
    if (outcome?.kind === "font" && outcome.dataURI && isStrictFontDataURI(outcome.dataURI)) {
      embedded.set(descriptor.src, outcome.dataURI);
    }
  }
  const rewritten = rewriteCSSURLs(css, (value, raw) => {
    const dataURI = value === null ? undefined : embedded.get(value.trim());
    return dataURI ? `url("${dataURI}")` : raw;
  });
  return { css: rewritten, allowedFontDataURIs: new Set(embedded.values()) };
}

export function sanitizeStyleText(css: string, allowedFontDataURIs: ReadonlySet<string>): string {
  // A style element is HTML raw text: CSS strings do not protect closing tags. Escape `<`
  // before the URL scan so the scanner sees the final text; escaping afterwards turned
  // `\<url(` into `\\3c url(`, an ident followed by a live url() token. Nothing may
  // transform the scanner's output.
  return sanitizeCSSURLs(css.replace(/</gu, "\\3c "), allowedFontDataURIs);
}

export function sanitizeStaticClone(
  root: HTMLElement,
  allowedFontDataURIs: ReadonlySet<string> = new Set(),
): void {
  root.querySelectorAll("script, iframe, frame, object, embed, applet, form, link, meta, base").forEach((node) => {
    node.remove();
  });

  for (const node of Array.from(root.querySelectorAll("*"))) {
    for (const attribute of Array.from(node.attributes)) {
      if (attribute.name.toLowerCase().startsWith("on")) node.removeAttribute(attribute.name);
    }
  }

  for (const style of root.querySelectorAll("style")) {
    style.textContent = sanitizeStyleText(style.textContent ?? "", allowedFontDataURIs);
  }

  for (const checkbox of root.querySelectorAll<HTMLInputElement>('input[type="checkbox"]')) {
    checkbox.disabled = true;
    checkbox.removeAttribute("data-task-checkbox");
  }

  enforceExportURLSinks(root, allowedFontDataURIs);

  for (const image of Array.from(root.querySelectorAll("img"))) {
    if (!isStrictImageDataURI(image.getAttribute("src") ?? "")) {
      image.replaceWith(placeholderElement(image, placeholderLabel(image, null)));
    }
  }
}

export function enforceExportURLSinks(
  root: HTMLElement,
  allowedFontDataURIs: ReadonlySet<string>,
): void {
  for (const svg of Array.from(root.querySelectorAll("svg"))) {
    if (!svg.closest(generatedSVGSelector)) svg.remove();
  }

  for (const node of Array.from(root.querySelectorAll("*"))) {
    if (node.hasAttribute("style")) {
      node.setAttribute("style", sanitizeStyleText(node.getAttribute("style") ?? "", allowedFontDataURIs));
    }
    sanitizeURLAttributes(node, allowedFontDataURIs);
  }
}

export function placeholderLabel(image: HTMLImageElement, reason?: string | null): string {
  if (reason === EXPORT_IMAGE_SIZE_LIMIT_REASON) return EXPORT_IMAGE_SIZE_LIMIT_REASON;
  return image.getAttribute("alt")?.trim() || EXPORT_IMAGE_PLACEHOLDER_LABEL;
}

export function placeholderElement(owner: Element, label: string): HTMLSpanElement {
  const placeholder = owner.ownerDocument.createElement("span");
  placeholder.className = "export-image-placeholder";
  placeholder.setAttribute("role", "img");
  placeholder.setAttribute("aria-label", label);
  placeholder.textContent = label;
  return placeholder;
}

function sanitizeURLAttributes(node: Element, allowedFontDataURIs: ReadonlySet<string>): void {
  const isSVG = node.namespaceURI === svgNamespace;
  for (const attribute of Array.from(node.attributes)) {
    const name = attribute.name.toLowerCase();
    if (removedURLAttributes.has(name) || (name === "data" && node.tagName === "OBJECT")) {
      node.removeAttribute(attribute.name);
      continue;
    }
    if (isSVG && cssValuedSVGAttributes.has(name)) {
      const sanitized = sanitizeCSSURLs(attribute.value, allowedFontDataURIs);
      if (sanitized !== attribute.value) node.setAttribute(attribute.name, sanitized);
      continue;
    }
    if (name !== "href" && name !== "xlink:href" && name !== "src") continue;
    if (!isRetainedURL(node, name, attribute.value)) node.removeAttribute(attribute.name);
  }
}

function isRetainedURL(node: Element, name: string, value: string): boolean {
  const trimmed = value.trim();
  if (node.tagName === "IMG" && name === "src") return isStrictImageDataURI(trimmed);
  if (node.closest("svg") && (name === "href" || name === "xlink:href")) {
    return trimmed.startsWith("#") && !trimmed.startsWith("#//") && !trimmed.includes("\\");
  }
  if (name === "href" || name === "xlink:href") return isAllowedExportLink(trimmed);
  return false;
}

function isAllowedExportLink(href: string): boolean {
  if (href.startsWith("#")) return !href.startsWith("#//") && !href.includes("\\");
  try {
    const url = new URL(href);
    return url.protocol === "https:" || url.protocol === "http:" || url.protocol === "mailto:";
  } catch {
    return false;
  }
}
