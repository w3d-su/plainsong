import type {
  ExportHTMLPayload,
  ExportHTMLResultPayload,
  ExportResourceDescriptor,
} from "./bridge";
import {
  EXPORT_IMAGE_SIZE_LIMIT_REASON,
  collectFontResources,
  embedFontSources,
  sanitizeStaticClone,
  sanitizeStyleText,
} from "./export-html-assets";
import {
  type ExportImageDecoder,
  applySerializedImageBudget,
  collectImageResources,
  decodeImageCandidates,
  detachExportImages,
  everyRetainedImageDecoded,
  matchesDiscoveredImages,
} from "./export-html-images";
import {
  EXPORT_CSP,
  EXPORT_IMAGE_PLACEHOLDER_LABEL,
  MAXIMUM_EXPORT_HTML_UTF8_BYTES,
} from "./export-html-limits";
import { isStrictImageDataURI, resolveResourceOutcomes } from "./export-html-outcomes";
import { escapeHtml } from "./mdx-error";

export {
  EXPORT_CSP,
  EXPORT_IMAGE_PLACEHOLDER_LABEL,
  EXPORT_IMAGE_SIZE_LIMIT_REASON,
  MAXIMUM_EXPORT_HTML_UTF8_BYTES,
};
export { collectImageResources, sanitizeStaticClone, sanitizeStyleText };

export type FrozenExportTheme = "light" | "dark";

export interface ExportHTMLHost {
  /**
   * The dedicated offscreen export controller's preview root (D1); never the visible
   * pane's. Only a successful finalization mutates it, replacing its children with the
   * finalized static nodes synchronously before `ready` is posted. Failed or superseded
   * exports leave it untouched.
   */
  previewRoot: HTMLElement;
  latestRenderID: number;
  documentTheme: string;
  bundledStyleText?: string;
  collectStyleText: () => string | Promise<string>;
  waitForFonts: () => Promise<void>;
  /** Defaults to accepting every strict data URI, for hosts without an image decoder. */
  decodeImage?: ExportImageDecoder;
  /** Test seam: can only tighten the D3 64 MiB limit. */
  maximumHTMLUTF8Bytes?: number;
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
  maximumUTF8Bytes?: number;
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

  const limit = Math.min(options.maximumUTF8Bytes ?? MAXIMUM_EXPORT_HTML_UTF8_BYTES, MAXIMUM_EXPORT_HTML_UTF8_BYTES);
  if (new TextEncoder().encode(html).length > limit) {
    return { failed: "html-too-large" };
  }
  return { html };
}

/** Production decoder: WebKit must decode the exact data URI the static file embeds. */
export async function decodeExportImageDataURI(dataURI: string): Promise<boolean> {
  const image = new Image();
  image.src = dataURI;
  try {
    await image.decode();
  } catch {
    return false;
  }
  return image.naturalWidth > 0 && image.naturalHeight > 0;
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
  const inlineCSS = Array.from(host.previewRoot.querySelectorAll("style"), (style) => style.textContent ?? "");
  const resources = [
    ...collectImageResources(host.previewRoot),
    ...collectFontResources(host.bundledStyleText ?? "", ...inlineCSS),
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
  const session = pendingExport;
  if (!session || !canFinalize(payload, session)) {
    fail("invalid-finalization");
    return;
  }
  session.finalizing = true;
  const superseded = (): boolean => pendingExport !== session;

  // Work in an inert document: nothing loads while the static clone is rewritten.
  const inert = host.previewRoot.ownerDocument.implementation.createHTMLDocument("");
  const clone = inert.importNode(host.previewRoot, true);
  const images = Array.from(clone.querySelectorAll("img"));
  if (!matchesDiscoveredImages(images, session.resources)) {
    fail("resources-changed");
    return;
  }
  const outcomes = resolveResourceOutcomes(session.resources, payload.resourceOutcomes);
  const fonts = embedFontSources(await host.collectStyleText(), session.resources, outcomes);
  if (superseded()) {
    fail("superseded");
    return;
  }

  const title = session.documentTitle?.trim() || firstHeadingText(clone);
  const frozenTheme = freezeExportTheme(host.documentTheme);
  const limit = Math.min(host.maximumHTMLUTF8Bytes ?? MAXIMUM_EXPORT_HTML_UTF8_BYTES, MAXIMUM_EXPORT_HTML_UTF8_BYTES);
  const build = (bodyHTML: string) => buildStaticExportHTML({
    bodyHTML,
    frozenTheme,
    styleText: fonts.css,
    title,
    allowedFontDataURIs: fonts.allowedFontDataURIs,
    maximumUTF8Bytes: limit,
  });

  const slots = detachExportImages(images, outcomes, fonts.allowedFontDataURIs);
  sanitizeStaticClone(clone, fonts.allowedFontDataURIs);
  await decodeImageCandidates(slots, host.decodeImage ?? acceptStrictDataURI);
  if (superseded()) {
    fail("superseded");
    return;
  }

  // Measure the already-sanitized document so the budget and the final check agree.
  const budget = applySerializedImageBudget({
    clone,
    slots,
    limit,
    measure: (bodyHTML) => {
      const built = build(bodyHTML);
      return "failed" in built ? null : new TextEncoder().encode(built.html).length;
    },
  });
  if (budget.status === "base-too-large") {
    fail("html-too-large");
    return;
  }

  await host.waitForFonts();
  if (superseded() || isExportBlocked(host.previewRoot)) {
    fail(superseded() ? "superseded" : "became-unready");
    return;
  }
  if (!everyRetainedImageDecoded(clone, slots)) {
    fail("image-undecoded");
    return;
  }
  const built = build(clone.innerHTML);
  if ("failed" in built) {
    fail(built.failed);
    return;
  }

  // D2: the finalized live export DOM. No await follows, so nothing can supersede it.
  const finalized = inert.createDocumentFragment();
  while (clone.firstChild) finalized.appendChild(clone.firstChild);
  host.previewRoot.replaceChildren(finalized);
  pendingExport = null;
  host.postResult({
    exportID: payload.exportID,
    renderID: payload.renderID,
    state: { kind: "ready", html: built.html },
  });
}

function canFinalize(payload: ExportHTMLPayload, session: PendingExport): boolean {
  return payload.phase === "finalization" &&
    session.exportID === payload.exportID &&
    session.renderID === payload.renderID &&
    !session.finalizing;
}

async function acceptStrictDataURI(dataURI: string): Promise<boolean> {
  return isStrictImageDataURI(dataURI);
}

function firstHeadingText(root: ParentNode): string {
  return Array.from(root.querySelectorAll("h1, h2, h3, h4, h5, h6"))
    .find((heading) => !heading.closest(".mdx-component-card"))?.textContent?.trim() || "Untitled";
}
