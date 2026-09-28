import type { ExportResourceDescriptor, ExportResourceOutcome } from "./bridge";
import { isAllowedDataImageSource } from "./image-policy";
import {
  EXPORT_IMAGE_PLACEHOLDER_LABEL,
  MAXIMUM_EXPORT_HTML_UTF8_BYTES,
} from "./export-html-limits";

export const EXPORT_IMAGE_SIZE_LIMIT_REASON = "Export image size limit";

const urlPattern = /url\(\s*(['"]?)([^'")]+)\1\s*\)/giu;
const generatedSVGSelector = ".katex, .mermaid-rendered";

export function utf8ByteLength(value: string): number {
  return new TextEncoder().encode(value).length;
}

export function collectFontResources(css: string): ExportResourceDescriptor[] {
  const seen = new Set<string>();
  const resources: ExportResourceDescriptor[] = [];
  for (const match of css.matchAll(urlPattern)) {
    const src = match[2]?.trim() ?? "";
    if (!src || src.startsWith("#") || /^data:/iu.test(src) || seen.has(src)) continue;
    seen.add(src);
    resources.push({ resourceID: `font-${resources.length}`, kind: "font", src });
  }
  return resources;
}

export function embedFontSources(
  css: string,
  descriptors: readonly ExportResourceDescriptor[],
  outcomes: readonly ExportResourceOutcome[],
): { css: string; allowedFontDataURIs: Set<string> } {
  const byID = new Map(outcomes.map((outcome) => [outcome.resourceID, outcome]));
  const embedded = new Map<string, string>();
  for (const descriptor of descriptors) {
    if (descriptor.kind !== "font") continue;
    const outcome = byID.get(descriptor.resourceID);
    if (outcome?.action === "embed" && outcome.dataURI) {
      embedded.set(descriptor.src.trim(), outcome.dataURI);
    }
  }
  const allowedFontDataURIs = new Set(embedded.values());
  const rewritten = css.replace(urlPattern, (match, _quote: string, value: string) => {
    const dataURI = embedded.get(value.trim());
    return dataURI ? `url("${dataURI}")` : match;
  });
  return { css: rewritten, allowedFontDataURIs };
}

export function sanitizeStyleText(css: string, allowedFontDataURIs: ReadonlySet<string>): string {
  return css
    .replace(/</gu, "\\3c ")
    .replace(urlPattern, (match, _quote: string, value: string) => {
      const trimmed = value.trim();
      if (trimmed.startsWith("#")) return match;
      if (allowedFontDataURIs.has(trimmed) && /^data:font\//iu.test(trimmed)) return match;
      return "url()";
    });
}

export function enforceExportURLSinks(
  root: HTMLElement,
  allowedFontDataURIs: ReadonlySet<string>,
): void {
  for (const svg of Array.from(root.querySelectorAll("svg"))) {
    if (!svg.closest(generatedSVGSelector)) svg.remove();
  }

  for (const node of Array.from(root.querySelectorAll("*"))) {
    if (node instanceof HTMLElement && node.hasAttribute("style")) {
      node.setAttribute("style", sanitizeStyleText(node.getAttribute("style") ?? "", allowedFontDataURIs));
    }
    sanitizeURLAttributes(node);
  }
}

export function imageOutcomeReason(
  outcomes: readonly ExportResourceOutcome[],
  resourceID: string,
): string | null {
  return outcomes.find((outcome) => outcome.resourceID === resourceID)?.reason ?? null;
}

export interface SerializedImageBudget {
  status: "ok" | "base-too-large";
  byteLength: number;
}

export function applySerializedImageBudget(options: {
  clone: HTMLElement;
  outcomes: readonly ExportResourceOutcome[];
  measure: (bodyHTML: string) => number | null;
  limit?: number;
}): SerializedImageBudget {
  const limit = options.limit ?? MAXIMUM_EXPORT_HTML_UTF8_BYTES;
  const images = Array.from(options.clone.querySelectorAll("img"));
  const slots = images.map((image, index) => {
    const outcome = options.outcomes.find((candidate) => candidate.resourceID === `image-${index}`);
    const placeholder = placeholderElement(image, placeholderLabel(image, outcome?.reason));
    image.replaceWith(placeholder);
    return { image, outcome, placeholder };
  });

  const baseLength = options.measure(options.clone.innerHTML);
  if (baseLength === null || baseLength > limit) {
    return { status: "base-too-large", byteLength: baseLength ?? Number.POSITIVE_INFINITY };
  }

  let used = baseLength;
  for (const slot of slots) {
    const embedded = slot.outcome?.action === "embed" ? slot.outcome.dataURI ?? "" : "";
    const original = slot.image.getAttribute("src") ?? "";
    const kept = embedded || (!slot.outcome && isAllowedDataImageSource(original) ? original : "");
    if (!isAllowedDataImageSource(kept)) continue;
    slot.image.setAttribute("src", kept);
    const delta = utf8ByteLength(slot.image.outerHTML) - utf8ByteLength(slot.placeholder.outerHTML);
    if (used + delta > limit) {
      slot.placeholder.replaceWith(placeholderElement(slot.image, EXPORT_IMAGE_SIZE_LIMIT_REASON));
      continue;
    }
    slot.placeholder.replaceWith(slot.image);
    used += delta;
  }

  return { status: "ok", byteLength: used };
}

export function placeholderLabel(image: HTMLImageElement, reason?: string | null): string {
  if (reason === EXPORT_IMAGE_SIZE_LIMIT_REASON) return EXPORT_IMAGE_SIZE_LIMIT_REASON;
  return image.getAttribute("alt")?.trim() || EXPORT_IMAGE_PLACEHOLDER_LABEL;
}

export function placeholderElement(image: HTMLImageElement, label: string): HTMLSpanElement {
  const placeholder = image.ownerDocument.createElement("span");
  placeholder.className = "export-image-placeholder";
  placeholder.setAttribute("role", "img");
  placeholder.setAttribute("aria-label", label);
  placeholder.textContent = label;
  return placeholder;
}

function sanitizeURLAttributes(node: Element): void {
  for (const attribute of Array.from(node.attributes)) {
    const name = attribute.name.toLowerCase();
    if (name === "srcset" || name === "poster" || name === "action" || name === "formaction" ||
      name === "cite" || name === "background" || (name === "data" && node.tagName === "OBJECT")) {
      node.removeAttribute(attribute.name);
      continue;
    }
    if (name !== "href" && name !== "xlink:href" && name !== "src") continue;
    if (!isRetainedURL(node, name, attribute.value)) node.removeAttribute(attribute.name);
  }
}

function isRetainedURL(node: Element, name: string, value: string): boolean {
  const trimmed = value.trim();
  if (node.tagName === "IMG" && name === "src") return isAllowedDataImageSource(trimmed);
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
