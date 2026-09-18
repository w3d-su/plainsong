import { isAllowedDataImageSource } from "./image-policy";
import { escapeHtml } from "./mdx-error";
import type {
  ExportHTMLPayload,
  ExportHTMLResultPayload,
  ExportResourceDescriptor,
  ExportResourceOutcome,
} from "./bridge";

export const EXPORT_CSP =
  "default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:; connect-src 'none'; media-src 'none'; object-src 'none'; frame-src 'none'; base-uri 'none'; form-action 'none'";

export const EXPORT_IMAGE_PLACEHOLDER_LABEL = "Image unavailable in export";
export const MAXIMUM_EXPORT_HTML_UTF8_BYTES = 64 * 1024 * 1024;

export type FrozenExportTheme = "light" | "dark";

export interface ExportHTMLHost {
  previewRoot: HTMLElement;
  latestRenderID: number;
  documentTheme: string;
  collectStyleText: () => string | Promise<string>;
  waitForFonts: () => Promise<void>;
  postResult: (payload: ExportHTMLResultPayload) => void;
}

interface PendingExport {
  exportID: number;
  renderID: number;
  documentTitle: string | null;
  finalizing: boolean;
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
  return globalThis.matchMedia?.("(prefers-color-scheme: dark)").matches === true
    ? "dark"
    : "light";
}

export function collectImageResources(root: ParentNode): ExportResourceDescriptor[] {
  return Array.from(root.querySelectorAll("img")).flatMap((image, index) => {
    const resourceID = `image-${index}`;
    const src =
      image.getAttribute("src") ??
      image.dataset.plainsongBlockedSrc ??
      image.dataset.plainsongOriginalSrc ??
      "";
    return isAllowedDataImageSource(src) ? [] : [{ resourceID, kind: "image" as const, src }];
  });
}

export function applyResourceOutcomes(
  root: ParentNode,
  outcomes: readonly ExportResourceOutcome[],
): void {
  const byID = new Map(outcomes.map((outcome) => [outcome.resourceID, outcome]));
  for (const [index, image] of Array.from(root.querySelectorAll("img")).entries()) {
    if (isAllowedDataImageSource(image.getAttribute("src") ?? "")) continue;
    const outcome = byID.get(`image-${index}`);
    if (outcome?.action === "embed" && typeof outcome.dataURI === "string" && outcome.dataURI.length > 0) {
      image.setAttribute("src", outcome.dataURI);
      continue;
    }
    replaceImageWithPlaceholder(image);
  }
}

export function sanitizeStaticClone(root: HTMLElement): void {
  root
    .querySelectorAll("script, iframe, object, embed, form, link[rel='stylesheet']")
    .forEach((node) => {
      node.remove();
    });

  for (const node of Array.from(root.querySelectorAll("*"))) {
    for (const attribute of Array.from(node.attributes)) {
      if (attribute.name.toLowerCase().startsWith("on")) {
        node.removeAttribute(attribute.name);
      }
    }
  }

  // Renderer-injected style nodes in the body need the same raw-text protection.
  for (const style of root.querySelectorAll("style")) {
    style.textContent = sanitizeStyleText(style.textContent ?? "");
  }

  for (const checkbox of root.querySelectorAll<HTMLInputElement>('input[type="checkbox"]')) {
    checkbox.disabled = true;
    checkbox.removeAttribute("data-task-checkbox");
  }

  for (const anchor of root.querySelectorAll("a[href]")) {
    const href = anchor.getAttribute("href") ?? "";
    if (!isAllowedExportHref(href)) {
      anchor.removeAttribute("href");
    }
  }

  for (const image of Array.from(root.querySelectorAll("img"))) {
    const src = image.getAttribute("src") ?? "";
    if (!isAllowedDataImageSource(src)) {
      replaceImageWithPlaceholder(image);
    }
  }

}

export function sanitizeStyleText(css: string): string {
  // A style element is HTML raw text: CSS strings do not protect closing tags.
  return css.replace(/</gu, "\\3c ").replace(/url\(\s*(['"]?)([^'")]+)\1\s*\)/giu, (match, _quote: string, value: string) => {
    const trimmed = value.trim();
    if (trimmed.startsWith("#")) return match;
    if (/^data:font\//iu.test(trimmed) || /^data:application\/font/iu.test(trimmed)) {
      return match;
    }
    return "url()";
  });
}

export function collectLoadedStyles(styleSheets: StyleSheetList | ArrayLike<CSSStyleSheet>): string {
  const parts: string[] = [];
  for (const sheet of Array.from(styleSheets)) {
    try {
      const rules = sheet.cssRules;
      for (const rule of Array.from(rules)) {
        parts.push(rule.cssText);
      }
    } catch {
      // Cross-origin or unreadable sheets are omitted rather than failing export.
    }
  }
  return parts.join("\n");
}

export function collectPreviewStyleText(doc: Document, bundledCSS = ""): string {
  // Linked file:// stylesheets are unreadable through CSSOM in WebKit. The build
  // supplies their trusted bytes; CSSOM still adds renderer-injected styles.
  return [bundledCSS, collectLoadedStyles(doc.styleSheets)].filter(Boolean).join("\n");
}

export function buildStaticExportHTML(options: {
  bodyHTML: string;
  frozenTheme: FrozenExportTheme;
  styleText: string;
  title: string;
}): { html: string } | { failed: string } {
  const title = options.title.trim() || "Untitled";
  const html = [
    "<!DOCTYPE html>",
    `<html data-theme="${options.frozenTheme}">`,
    "<head>",
    '<meta charset="utf-8">',
    `<meta http-equiv="Content-Security-Policy" content="${EXPORT_CSP}">`,
    `<title>${escapeHtml(title)}</title>`,
    `<style>${sanitizeStyleText(options.styleText)}</style>`,
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
      const resources = collectImageResources(host.previewRoot);
      pendingExport = { exportID: payload.exportID, renderID: payload.renderID,
        documentTitle: payload.documentTitle ?? null, finalizing: false };
      host.postResult({
        exportID: payload.exportID,
        renderID: payload.renderID,
        state: { kind: "resourcesNeeded", resources },
      });
      return;
    }

    if (
      payload.phase !== "finalization" ||
      pendingExport === null ||
      pendingExport.exportID !== payload.exportID ||
      pendingExport.renderID !== payload.renderID ||
      pendingExport.finalizing
    ) {
      fail("invalid-finalization");
      return;
    }

    const session = pendingExport;
    session.finalizing = true;
    const clone = host.previewRoot.cloneNode(true) as HTMLElement;
    applyResourceOutcomes(clone, payload.resourceOutcomes);
    sanitizeStaticClone(clone);

    await host.waitForFonts();

    if (pendingExport !== session) {
      fail("superseded");
      return;
    }

    if (isExportBlocked(host.previewRoot)) {
      fail("became-unready");
      return;
    }

    for (const image of clone.querySelectorAll("img")) {
      if (!isAllowedDataImageSource(image.getAttribute("src") ?? "")) {
        fail("image-undecoded");
        return;
      }
    }

    const styleText = await host.collectStyleText();
    if (pendingExport !== session) {
      fail("superseded");
      return;
    }
    const built = buildStaticExportHTML({
      bodyHTML: clone.innerHTML,
      frozenTheme: freezeExportTheme(host.documentTheme),
      styleText,
      title: session.documentTitle?.trim() || firstHeadingText(clone),
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
  } catch {
    fail("serialization-failed");
  }
}

function replaceImageWithPlaceholder(image: HTMLImageElement): void {
  const alt = image.getAttribute("alt")?.trim() ?? "";
  const label = alt || EXPORT_IMAGE_PLACEHOLDER_LABEL;
  const placeholder = image.ownerDocument.createElement("span");
  placeholder.className = "export-image-placeholder";
  placeholder.setAttribute("role", "img");
  placeholder.setAttribute("aria-label", label);
  placeholder.textContent = label;
  image.replaceWith(placeholder);
}

function firstHeadingText(root: ParentNode): string {
  return Array.from(root.querySelectorAll("h1, h2, h3, h4, h5, h6"))
    .find((heading) => !heading.closest(".mdx-component-card"))?.textContent?.trim() || "Untitled";
}

function isAllowedExportHref(href: string): boolean {
  const trimmed = href.trim();
  if (trimmed.startsWith("#")) return true;
  try {
    const url = new URL(trimmed);
    return url.protocol === "https:" || url.protocol === "http:" || url.protocol === "mailto:";
  } catch {
    return false;
  }
}
