import type {
  ExportHTMLPayload,
  ExportHTMLResultPayload,
  ExportResourceDescriptor,
  ExportResourceOutcome,
} from "./bridge";
import {
  applySerializedImageBudget,
  collectFontResources,
  embedFontSources,
  enforceExportURLSinks,
  placeholderElement,
  placeholderLabel,
  sanitizeStyleText,
} from "./export-html-assets";
import {
  EXPORT_CSP,
  EXPORT_IMAGE_PLACEHOLDER_LABEL,
  MAXIMUM_EXPORT_HTML_UTF8_BYTES,
} from "./export-html-limits";
import { isAllowedDataImageSource } from "./image-policy";
import { escapeHtml } from "./mdx-error";

export {
  EXPORT_CSP,
  EXPORT_IMAGE_PLACEHOLDER_LABEL,
  MAXIMUM_EXPORT_HTML_UTF8_BYTES,
};
export { sanitizeStyleText };

export const EXPORT_IMAGE_SIZE_LIMIT_REASON = "Export image size limit";

export type FrozenExportTheme = "light" | "dark";

export interface ExportHTMLHost {
  previewRoot: HTMLElement;
  latestRenderID: number;
  documentTheme: string;
  bundledStyleText?: string;
  collectStyleText: () => string | Promise<string>;
  waitForFonts: () => Promise<void>;
  waitForImages?: (root: ParentNode) => Promise<void>;
  postResult: (payload: ExportHTMLResultPayload) => void;
}

interface PendingExport {
  exportID: number;
  renderID: number;
  documentTitle: string | null;
  finalizing: boolean;
  resources: ExportResourceDescriptor[];
}

let pendingExport: PendingExport | null = null;

export function resetExportHTMLSession(): void {
  pendingExport = null;
}

export function isExportBlocked(root: HTMLElement): string | null {
  if (root.classList.contains("preview-stale") || root.querySelector(".mdx-error-banner")) {
    return "mdx-stale-or-error";
  }
  if (root.querySelector(".mermaid-pending")) {
    return "mermaid-pending";
  }
  return null;
}

export function freezeExportTheme(theme: string): FrozenExportTheme {
  if (theme === "dark") return "dark";
  if (theme === "light") return "light";
  return globalThis.matchMedia?.("(prefers-color-scheme: dark)").matches === true ? "dark" : "light";
}

export function collectImageResources(root: ParentNode): ExportResourceDescriptor[] {
  return Array.from(root.querySelectorAll("img")).map((image, index) => ({
    resourceID: `image-${index}`,
    kind: "image" as const,
    src:
      image.getAttribute("src") ??
      image.dataset.plainsongBlockedSrc ??
      image.dataset.plainsongOriginalSrc ??
      "",
  }));
}

export function applyResourceOutcomes(
  root: ParentNode,
  outcomes: readonly ExportResourceOutcome[],
): void {
  const byID = new Map(outcomes.map((outcome) => [outcome.resourceID, outcome]));
  for (const [index, image] of Array.from(root.querySelectorAll("img")).entries()) {
    const outcome = byID.get(`image-${index}`);
    if (outcome?.action === "embed" && isAllowedDataImageSource(outcome.dataURI ?? "")) {
      image.setAttribute("src", outcome.dataURI ?? "");
      continue;
    }
    if (!outcome && isAllowedDataImageSource(image.getAttribute("src") ?? "")) continue;
    image.replaceWith(placeholderElement(image, placeholderLabel(image, outcome?.reason)));
  }
}

export function sanitizeStaticClone(
  root: HTMLElement,
  allowedFontDataURIs: ReadonlySet<string> = new Set(),
): void {
  root.querySelectorAll("script, iframe, object, embed, form, link[rel='stylesheet'], base").forEach((node) => {
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
    if (!isAllowedDataImageSource(image.getAttribute("src") ?? "")) {
      image.replaceWith(placeholderElement(image, placeholderLabel(image, null)));
    }
  }
}

export function collectLoadedStyles(styleSheets: StyleSheetList | ArrayLike<CSSStyleSheet>): string {
  const parts: string[] = [];
  for (const sheet of Array.from(styleSheets)) {
    try {
      for (const rule of Array.from(sheet.cssRules)) parts.push(rule.cssText);
    } catch {
      // Cross-origin or unreadable sheets are omitted rather than failing export.
    }
  }
  return parts.join("\n");
}

export function collectPreviewStyleText(doc: Document, bundledCSS = ""): string {
  return [bundledCSS, collectLoadedStyles(doc.styleSheets)].filter(Boolean).join("\n");
}

export function buildStaticExportHTML(options: {
  bodyHTML: string;
  frozenTheme: FrozenExportTheme;
  styleText: string;
  title: string;
  allowedFontDataURIs?: ReadonlySet<string>;
}): { html: string } | { failed: string } {
  const title = options.title.trim() || "Untitled";
  const html = [
    "<!DOCTYPE html>",
    `<html data-theme="${options.frozenTheme}">`,
    "<head>",
    '<meta charset="utf-8">',
    `<meta http-equiv="Content-Security-Policy" content="${EXPORT_CSP}">`,
    `<title>${escapeHtml(title)}</title>`,
    `<style>${sanitizeStyleText(options.styleText, options.allowedFontDataURIs ?? new Set())}</style>`,
    "</head>",
    "<body>",
    `<main id="preview-root">${options.bodyHTML}</main>`,
    "</body>",
    "</html>",
    "",
  ].join("\n");

  if (new TextEncoder().encode(html).length > MAXIMUM_EXPORT_HTML_UTF8_BYTES) {
    return { failed: "html-too-large" };
  }
  return { html };
}

export async function waitForRetainedImages(root: ParentNode): Promise<void> {
  await Promise.all(Array.from(root.querySelectorAll("img")).map((image) => (
    decodeRetainedImage(image.getAttribute("src") ?? "")
  )));
}

export async function handleExportHTML(
  payload: ExportHTMLPayload,
  host: ExportHTMLHost,
): Promise<void> {
  const fail = (reason: string): void => {
    if (pendingExport?.exportID === payload.exportID && pendingExport.renderID === payload.renderID) {
      pendingExport = null;
    }
    host.postResult({
      exportID: payload.exportID,
      renderID: payload.renderID,
      state: { kind: "failed", reason },
    });
  };

  try {
    if (payload.renderID !== host.latestRenderID) {
      fail("stale-render");
      return;
    }
    const blocked = isExportBlocked(host.previewRoot);
    if (blocked) {
      fail(blocked);
      return;
    }
    if (payload.phase === "discovery") {
      discoverExportResources(payload, host);
      return;
    }
    await finalizeExportHTML(payload, host, fail);
  } catch {
    fail("serialization-failed");
  }
}

function discoverExportResources(payload: ExportHTMLPayload, host: ExportHTMLHost): void {
  const inlineCSS = Array.from(host.previewRoot.querySelectorAll("style"))
    .map((style) => style.textContent ?? "")
    .join("\n");
  const resources = [
    ...collectImageResources(host.previewRoot),
    ...collectFontResources(host.bundledStyleText ?? ""),
    ...collectFontResources(inlineCSS),
  ];
  pendingExport = {
    exportID: payload.exportID,
    renderID: payload.renderID,
    documentTitle: payload.documentTitle ?? null,
    finalizing: false,
    resources,
  };
  host.postResult({
    exportID: payload.exportID,
    renderID: payload.renderID,
    state: { kind: "resourcesNeeded", resources },
  });
}

async function finalizeExportHTML(
  payload: ExportHTMLPayload,
  host: ExportHTMLHost,
  fail: (reason: string) => void,
): Promise<void> {
  if (!canFinalize(payload)) {
    fail("invalid-finalization");
    return;
  }
  const session = pendingExport;
  if (!session) {
    fail("invalid-finalization");
    return;
  }
  session.finalizing = true;
  const clone = host.previewRoot.cloneNode(true) as HTMLElement;
  const fonts = embedFontSources(await host.collectStyleText(), session.resources, payload.resourceOutcomes);
  if (pendingExport !== session) {
    fail("superseded");
    return;
  }

  const title = session.documentTitle?.trim() || firstHeadingText(clone);
  const frozenTheme = freezeExportTheme(host.documentTheme);
  const budget = applySerializedImageBudget({
    clone,
    outcomes: payload.resourceOutcomes,
    measure: (bodyHTML) => {
      const built = buildStaticExportHTML({
        bodyHTML,
        frozenTheme,
        styleText: fonts.css,
        title,
        allowedFontDataURIs: fonts.allowedFontDataURIs,
      });
      return "failed" in built ? null : new TextEncoder().encode(built.html).length;
    },
  });
  if (budget.status === "base-too-large") {
    fail("html-too-large");
    return;
  }

  host.previewRoot.innerHTML = clone.innerHTML;
  await host.waitForFonts();
  if (pendingExport !== session || isExportBlocked(host.previewRoot)) {
    fail(pendingExport !== session ? "superseded" : "became-unready");
    return;
  }
  try {
    await (host.waitForImages ?? assertImageSources)(clone);
  } catch (error) {
    if (error instanceof Error && error.message === "image-undecoded") {
      fail("image-undecoded");
      return;
    }
    throw error;
  }

  sanitizeStaticClone(clone, fonts.allowedFontDataURIs);
  const built = buildStaticExportHTML({
    bodyHTML: clone.innerHTML,
    frozenTheme,
    styleText: fonts.css,
    title,
    allowedFontDataURIs: fonts.allowedFontDataURIs,
  });
  if ("failed" in built) {
    fail(built.failed);
    return;
  }
  pendingExport = null;
  host.postResult({
    exportID: payload.exportID,
    renderID: payload.renderID,
    state: { kind: "ready", html: built.html },
  });
}

function canFinalize(payload: ExportHTMLPayload): boolean {
  return payload.phase === "finalization" &&
    pendingExport !== null &&
    pendingExport.exportID === payload.exportID &&
    pendingExport.renderID === payload.renderID &&
    !pendingExport.finalizing;
}

function assertImageSources(root: ParentNode): Promise<void> {
  for (const image of Array.from(root.querySelectorAll("img"))) {
    if (!isAllowedDataImageSource(image.getAttribute("src") ?? "")) {
      return Promise.reject(new Error("image-undecoded"));
    }
  }
  return Promise.resolve();
}

async function decodeRetainedImage(src: string): Promise<void> {
  if (!isAllowedDataImageSource(src)) throw new Error("image-undecoded");
  const image = new Image();
  image.src = src;
  if (typeof image.decode === "function") await image.decode();
  if ((image.naturalWidth ?? 0) <= 0) throw new Error("image-undecoded");
}

function firstHeadingText(root: ParentNode): string {
  return Array.from(root.querySelectorAll("h1, h2, h3, h4, h5, h6"))
    .find((heading) => !heading.closest(".mdx-component-card"))?.textContent?.trim() || "Untitled";
}
