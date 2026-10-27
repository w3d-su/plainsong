import {
  type BridgeMessage,
  PROTOCOL_VERSION,
  postBridgeMessage,
} from "./bridge";
import {
  collectPreviewStyleText,
  decodeExportImageDataURI,
  handleExportHTML,
  resetExportHTMLSession,
} from "./export-html";
import {
  highlightCodeBlocks,
  registerHighlightLanguages,
} from "./code-highlight";
import { rewriteImageSources } from "./image-rewrite";
import { scrollPreviewAnchor } from "./heading-anchors";
import {
  patchPreviewRoot,
  rerenderVisibleMermaidBlocks,
} from "./mermaid-dom";
import { LazyMermaid, loadMermaidScript } from "./mermaid-loader";
import { MermaidRenderCoordinator } from "./mermaid-renderer";
import { mdxErrorDetails } from "./mdx-error";
import { PreviewScrollIndex } from "./scroll-index";
import { SegmentedRenderer } from "./segmented-render";

export { PROTOCOL_VERSION } from "./bridge";

// Injected from the exact bundle.css inputs by build.mjs.
declare const __PLAINSONG_BUNDLED_CSS__: string;

type ScrollOwner = "editor" | "preview" | "none";

const previewRoot = requirePreviewRoot();
const scrollIndex = new PreviewScrollIndex(previewRoot);
// Rendered HTML is parsed here, where nothing loads: an <img> parsed into the live
// document starts fetching before rewriteImageSources can strip a remote src, which
// sent requests even with Allow Remote Images off. Nodes morphdom moves into the live
// tree are adopted with their rewritten sources.
const parsingDocument = document.implementation.createHTMLDocument("");

// Drop-ordering key. Monotonic across document switches, unlike `version` which
// resets per document — using `version` here stranded the preview on the previous
// file after editing it then switching to a freshly opened (lower-version) file.
let latestRenderID = -1;
// Document version of the currently displayed render; only used for checkbox writeback.
let currentRenderedVersion = -1;
let currentRenderedID = -1;
let currentBaseDir: string | null = null;
let currentAssetRootID = "";
let currentAllowRemoteImages = false;
let scrollOwner: ScrollOwner = "none";
let scrollOwnerTimer: number | undefined;
let scrollFrame: number | undefined;
// Keep the actual scroll position as well as its mapped source position. The inverse
// mapping can lose a fraction of a pixel (or clamp beyond the first/last anchor).
// Reflow applies only the change in anchor geometry, preserving that residual.
let scrollAnchor: { position: number; top: number; offset: number } | undefined;
let layoutWidth: number | undefined;
const scrollAnchorOffset = 12;

// Reuses the HTML of unchanged segments between renders (segmented-render.ts). Its cache holds
// the last rendered document only, so a change of file kind starts a new one rather than
// keeping the other kind's last document alive.
let renderer: SegmentedRenderer | undefined;
const mermaid = new LazyMermaid(() => loadMermaidScript(document));
const mermaidRenderer = new MermaidRenderCoordinator(mermaid.render, mermaid.initialize);

registerHighlightLanguages();
initializeMermaid("system");

window.PlainsongBridge = {
  receive(message: BridgeMessage) {
    void receive(message);
  },
};

window.PlainsongPreview = {
  PROTOCOL_VERSION,
};

window.addEventListener(
  "scroll",
  () => {
    if (scrollFrame !== undefined) return;

    scrollFrame = window.requestAnimationFrame(() => {
      scrollFrame = undefined;
      handlePreviewScroll();
    });
  },
  { passive: true },
);

// Resize callbacks run after layout and before paint, so the re-anchored scroll
// position is what the next frame shows. (jsdom has no ResizeObserver.)
if (typeof ResizeObserver !== "undefined") {
  new ResizeObserver(([entry]) => {
    const width = entry.contentRect.width;
    if (width === layoutWidth) return;
    const isReflow = layoutWidth !== undefined;
    layoutWidth = width;
    if (!isReflow || scrollAnchor === undefined) return;
    const top = scrollIndex.topForLine(scrollAnchor.position);
    // A width notification alone does not prove that the anchored content reflowed.
    // In particular, never round-trip an unchanged layout through window.scrollTo.
    if (top === undefined || top === scrollAnchor.top) return;
    scrollAnchor.top = top;
    const target = Math.max(0, top + scrollAnchor.offset);
    if (target !== window.scrollY) placeScrollTop(target, false);
  }).observe(previewRoot);
}

previewRoot.addEventListener("click", (event) => {
  const target = event.target;
  if (!(target instanceof Element)) return;

  const checkbox = target.closest<HTMLInputElement>(
    'input[data-task-checkbox="true"]',
  );
  if (checkbox) {
    const line = sourceLineForElement(checkbox);
    if (line !== undefined) {
      postBridgeMessage({
        name: "checkboxToggled",
        payload: { line, checked: checkbox.checked, version: currentRenderedVersion, renderID: currentRenderedID },
      });
    }
    return;
  }

  const link = target.closest<HTMLAnchorElement>("a[href]");
  if (!link) return;

  event.preventDefault();
  const href = link.getAttribute("href") ?? "";
  if (href.startsWith("#")) {
    setScrollOwner("preview");
    scrollPreviewAnchor(previewRoot, href);
    return;
  }
  postBridgeMessage({
    name: "linkClicked",
    payload: { href },
  });
});

postBridgeMessage({
  name: "ready",
  payload: { protocolVersion: PROTOCOL_VERSION },
});

async function receive(message: BridgeMessage): Promise<void> {
  switch (message.name) {
    case "render":
      await render(message.payload);
      break;
    case "scrollToLine":
      scrollToLine(message.payload.line, message.payload.animated);
      break;
    case "setTheme": {
      const themeChanged = applyPreviewSettings(
        message.payload.theme,
        message.payload.allowRemoteImages,
      );
      rewriteImageSources(previewRoot, currentBaseDir, currentAllowRemoteImages, currentAssetRootID);
      if (themeChanged) {
        await rerenderVisibleMermaidBlocks(previewRoot, mermaidRenderer);
      }
      break;
    }
    case "exportHTML":
      await handleExportHTML(message.payload, {
        previewRoot,
        latestRenderID,
        documentTheme: document.documentElement.dataset.theme ?? "system",
        bundledStyleText: __PLAINSONG_BUNDLED_CSS__,
        collectStyleText: () => collectPreviewStyleText(document, __PLAINSONG_BUNDLED_CSS__),
        waitForFonts: async () => {
          if (document.fonts?.ready) {
            await document.fonts.ready;
          }
        },
        decodeImage: decodeExportImageDataURI,
        postResult: (payload) => {
          postBridgeMessage({ name: "exportHTMLResult", payload });
        },
      });
      break;
    case "ready":
    case "renderComplete":
    case "previewScrolled":
    case "linkClicked":
    case "checkboxToggled":
    case "exportHTMLResult":
      break;
  }
}

async function render(payload: Extract<BridgeMessage, { name: "render" }>["payload"]) {
  if (payload.renderID < latestRenderID) return;
  resetExportHTMLSession();
  latestRenderID = payload.renderID;
  applyPreviewSettings(payload.theme, payload.allowRemoteImages);

  let html: string;
  try {
    if (renderer?.fileKind !== payload.fileKind) renderer = new SegmentedRenderer(payload.fileKind);
    html = await renderer.render(payload.text);
  } catch (error) {
    if (payload.fileKind !== "mdx") throw error;
    if (payload.renderID < latestRenderID) return;

    showMdxErrorBanner(error);
    postBridgeMessage({
      name: "renderComplete",
      payload: {
        renderID: payload.renderID,
        version: payload.version,
        blockCount: previewRoot.querySelectorAll("[data-line]").length,
      },
    });
    return;
  }

  if (payload.renderID < latestRenderID) return;

  const nextRoot = parsingDocument.createElement("main");
  nextRoot.id = "preview-root";
  nextRoot.innerHTML = html;
  rewriteImageSources(nextRoot, payload.baseDir, payload.allowRemoteImages, payload.assetRootID);

  clearMdxErrorBanner();
  const mermaidPatch = patchPreviewRoot(previewRoot, nextRoot, mermaidRenderer);
  // The checkbox provenance changes with the DOM, before asynchronous diagrams settle.
  currentRenderedID = payload.renderID;
  currentRenderedVersion = payload.version;
  currentBaseDir = payload.baseDir;
  currentAssetRootID = payload.assetRootID;
  highlightCodeBlocks(previewRoot);
  await mermaidPatch;
  if (payload.renderID < latestRenderID) return;

  postBridgeMessage({
    name: "renderComplete",
    payload: {
      renderID: payload.renderID,
      version: payload.version,
      blockCount: previewRoot.querySelectorAll("[data-line]").length,
    },
  });
}

function showMdxErrorBanner(error: unknown): void {
  previewRoot.classList.add("preview-stale");

  const details = mdxErrorDetails(error);
  let banner = previewRoot.querySelector<HTMLElement>(".mdx-error-banner");
  if (!banner) {
    banner = document.createElement("aside");
    banner.className = "mdx-error-banner";
    banner.setAttribute("role", "status");
    previewRoot.prepend(banner);
  }

  const title = document.createElement("strong");
  title.textContent =
    details.line === undefined ? "MDX syntax error" : `MDX syntax error on line ${details.line}`;

  const message = document.createElement("span");
  message.textContent = details.message;

  banner.replaceChildren(title, message);
}

function clearMdxErrorBanner(): void {
  previewRoot.classList.remove("preview-stale");
  previewRoot.querySelector(".mdx-error-banner")?.remove();
}

function scrollToLine(line: number, animated: boolean): void {
  const targetTop = scrollIndex.topForLine(line);
  if (targetTop === undefined) return;
  const target = Math.max(0, targetTop - scrollAnchorOffset);
  // Use the destination even for smooth scrolling, whose current scrollY still
  // belongs to the beginning of the animation.
  scrollAnchor = { position: line, top: targetTop, offset: target - targetTop };
  placeScrollTop(target, animated);
}

function placeScrollTop(top: number, animated: boolean): void {
  // Programmatic scrolling is never reported back to the editor.
  setScrollOwner("editor");
  window.scrollTo({
    top,
    behavior: animated ? "smooth" : "auto",
  });
}

function handlePreviewScroll(): void {
  if (scrollOwner === "editor") return;

  const position = scrollIndex.positionAtTop(window.scrollY + scrollAnchorOffset);
  const top = position === undefined ? undefined : scrollIndex.topForLine(position);
  scrollAnchor = position === undefined || top === undefined ? undefined : { position, top, offset: window.scrollY - top };
  const topVisibleLine = scrollIndex.lineAtTop(window.scrollY + 16);
  if (topVisibleLine === undefined) return;

  setScrollOwner("preview");
  postBridgeMessage({
    name: "previewScrolled",
    payload: { topVisibleLine },
  });
}

function setScrollOwner(owner: ScrollOwner): void {
  scrollOwner = owner;
  if (scrollOwnerTimer !== undefined) {
    window.clearTimeout(scrollOwnerTimer);
  }
  scrollOwnerTimer = window.setTimeout(() => {
    scrollOwner = "none";
    scrollOwnerTimer = undefined;
  }, 100);
}

function sourceLineForElement(element: Element): number | undefined {
  const lineElement = element.closest<HTMLElement>("[data-line]");
  const line = Number.parseInt(lineElement?.dataset.line ?? "", 10);
  return Number.isFinite(line) ? line : undefined;
}

function applyPreviewSettings(theme: string, allowRemoteImages: boolean): boolean {
  document.documentElement.dataset.theme = theme;
  currentAllowRemoteImages = allowRemoteImages;
  return initializeMermaid(theme);
}

function requirePreviewRoot(): HTMLElement {
  const root = document.getElementById("preview-root");
  if (!root) {
    throw new Error("Missing preview root");
  }
  return root;
}

function initializeMermaid(theme: string): boolean {
  return mermaidRenderer.initializeTheme(theme);
}
