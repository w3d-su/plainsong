import hljs from "highlight.js/lib/core";
import bash from "highlight.js/lib/languages/bash";
import css from "highlight.js/lib/languages/css";
import go from "highlight.js/lib/languages/go";
import javascript from "highlight.js/lib/languages/javascript";
import json from "highlight.js/lib/languages/json";
import markdown from "highlight.js/lib/languages/markdown";
import python from "highlight.js/lib/languages/python";
import rust from "highlight.js/lib/languages/rust";
import swift from "highlight.js/lib/languages/swift";
import typescript from "highlight.js/lib/languages/typescript";
import xml from "highlight.js/lib/languages/xml";
import yaml from "highlight.js/lib/languages/yaml";
import mermaid from "mermaid";
import morphdom from "morphdom";
import {
  type BridgeMessage,
  PROTOCOL_VERSION,
  postBridgeMessage,
} from "./bridge";
import { rewriteImageSources } from "./image-rewrite";
import { mdxErrorDetails } from "./mdx-error";
import { renderMarkdown, renderMdx } from "./pipeline";

export { PROTOCOL_VERSION } from "./bridge";

type ScrollOwner = "editor" | "preview" | "none";

const previewRoot = requirePreviewRoot();

// Drop-ordering key. Monotonic across document switches, unlike `version` which
// resets per document — using `version` here stranded the preview on the previous
// file after editing it then switching to a freshly opened (lower-version) file.
let latestRenderID = -1;
// Document version of the currently displayed render; only used for checkbox writeback.
let currentRenderedVersion = -1;
let currentBaseDir: string | null = null;
let currentAllowRemoteImages = false;
let scrollOwner: ScrollOwner = "none";
let scrollOwnerTimer: number | undefined;
let scrollFrame: number | undefined;

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
        payload: { line, checked: checkbox.checked, version: currentRenderedVersion },
      });
    }
    return;
  }

  const link = target.closest<HTMLAnchorElement>("a[href]");
  if (!link) return;

  event.preventDefault();
  postBridgeMessage({
    name: "linkClicked",
    payload: { href: link.getAttribute("href") ?? "" },
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
    case "setTheme":
      applyPreviewSettings(message.payload.theme, message.payload.allowRemoteImages);
      rewriteImageSources(previewRoot, currentBaseDir, currentAllowRemoteImages);
      break;
    case "ready":
    case "renderComplete":
    case "previewScrolled":
    case "linkClicked":
    case "checkboxToggled":
      break;
  }
}

async function render(payload: Extract<BridgeMessage, { name: "render" }>["payload"]) {
  if (payload.renderID < latestRenderID) return;
  latestRenderID = payload.renderID;
  currentBaseDir = payload.baseDir;
  applyPreviewSettings(payload.theme, payload.allowRemoteImages);

  let html: string;
  try {
    html =
      payload.fileKind === "md"
        ? await renderMarkdown(payload.text)
        : await renderMdx(payload.text);
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

  const nextRoot = document.createElement("main");
  nextRoot.id = "preview-root";
  nextRoot.innerHTML = html;
  rewriteImageSources(nextRoot, payload.baseDir, payload.allowRemoteImages);

  clearMdxErrorBanner();
  morphdom(previewRoot, nextRoot, {
    childrenOnly: true,
    onBeforeElUpdated: preserveUnchangedHighlightedCode,
  });
  highlightCodeBlocks();
  await renderMermaidBlocks();
  if (payload.renderID < latestRenderID) return;
  currentRenderedVersion = payload.version;

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
  const targetTop = interpolatedTopForLine(line);
  if (targetTop === undefined) return;

  setScrollOwner("editor");
  window.scrollTo({
    top: Math.max(0, targetTop - 12),
    behavior: animated ? "smooth" : "auto",
  });
}

function handlePreviewScroll(): void {
  if (scrollOwner === "editor") return;

  const topVisibleLine = topVisibleLineFromScroll();
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

function lineAnchors(): Array<{ line: number; element: HTMLElement }> {
  return Array.from(previewRoot.querySelectorAll<HTMLElement>("[data-line]"))
    .map((element) => ({
      element,
      line: Number.parseInt(element.dataset.line ?? "", 10),
    }))
    .filter(({ line }) => Number.isFinite(line))
    .sort((a, b) => a.line - b.line);
}

function interpolatedTopForLine(line: number): number | undefined {
  const anchors = lineAnchors();
  if (anchors.length === 0) return undefined;

  let previous = anchors[0];
  let next = anchors[anchors.length - 1];

  for (const anchor of anchors) {
    if (anchor.line <= line) previous = anchor;
    if (anchor.line > line) {
      next = anchor;
      break;
    }
  }

  if (previous === next || next.line <= previous.line) {
    return previous.element.offsetTop;
  }

  const progress = (line - previous.line) / (next.line - previous.line);
  return (
    previous.element.offsetTop +
    (next.element.offsetTop - previous.element.offsetTop) * progress
  );
}

function topVisibleLineFromScroll(): number | undefined {
  const y = window.scrollY + 16;
  let bestLine: number | undefined;

  for (const anchor of lineAnchors()) {
    if (anchor.element.offsetTop > y) break;
    bestLine = anchor.line;
  }

  return bestLine;
}

function sourceLineForElement(element: Element): number | undefined {
  const lineElement = element.closest<HTMLElement>("[data-line]");
  const line = Number.parseInt(lineElement?.dataset.line ?? "", 10);
  return Number.isFinite(line) ? line : undefined;
}

function applyPreviewSettings(theme: string, allowRemoteImages: boolean): void {
  document.documentElement.dataset.theme = theme;
  currentAllowRemoteImages = allowRemoteImages;
  initializeMermaid(theme);
}

function highlightCodeBlocks(): void {
  for (const code of previewRoot.querySelectorAll<HTMLElement>("pre code")) {
    if (code.classList.contains("language-mermaid")) continue;
    if (code.dataset.highlighted) continue;

    hljs.highlightElement(code);
  }
}

function preserveUnchangedHighlightedCode(fromElement: Element, toElement: Element): boolean {
  if (!(fromElement instanceof HTMLElement) || !(toElement instanceof HTMLElement)) {
    return true;
  }
  if (!fromElement.matches("pre code") || !toElement.matches("pre code")) {
    return true;
  }
  return (
    fromElement.textContent !== toElement.textContent ||
    codeLanguageClass(fromElement) !== codeLanguageClass(toElement)
  );
}

function codeLanguageClass(element: HTMLElement): string {
  return (
    Array.from(element.classList).find(
      (className) => className.startsWith("language-") || className.startsWith("lang-"),
    ) ?? ""
  );
}

async function renderMermaidBlocks(): Promise<void> {
  const blocks = Array.from(
    previewRoot.querySelectorAll<HTMLElement>(
      "pre > code.language-mermaid, pre > code.lang-mermaid",
    ),
  );

  for (const [index, code] of blocks.entries()) {
    const source = code.textContent ?? "";
    const hash = hashString(source);
    const wrapper = document.createElement("div");
    wrapper.className = "mermaid-rendered";
    wrapper.dataset.mermaidHash = hash;

    try {
      const rendered = await mermaid.render(`mermaid-${hash}-${index}`, source);
      wrapper.innerHTML = rendered.svg;
      code.closest("pre")?.replaceWith(wrapper);
    } catch (error) {
      wrapper.classList.add("mermaid-error");
      wrapper.textContent = error instanceof Error ? error.message : String(error);
      code.closest("pre")?.replaceWith(wrapper);
    }
  }
}

function hashString(value: string): string {
  let hash = 5381;
  for (let index = 0; index < value.length; index += 1) {
    hash = (hash * 33) ^ value.charCodeAt(index);
  }
  return (hash >>> 0).toString(36);
}

function registerHighlightLanguages(): void {
  hljs.registerLanguage("bash", bash);
  hljs.registerLanguage("css", css);
  hljs.registerLanguage("go", go);
  hljs.registerLanguage("html", xml);
  hljs.registerLanguage("javascript", javascript);
  hljs.registerLanguage("js", javascript);
  hljs.registerLanguage("json", json);
  hljs.registerLanguage("markdown", markdown);
  hljs.registerLanguage("md", markdown);
  hljs.registerLanguage("python", python);
  hljs.registerLanguage("py", python);
  hljs.registerLanguage("rust", rust);
  hljs.registerLanguage("rs", rust);
  hljs.registerLanguage("sh", bash);
  hljs.registerLanguage("swift", swift);
  hljs.registerLanguage("typescript", typescript);
  hljs.registerLanguage("ts", typescript);
  hljs.registerLanguage("xml", xml);
  hljs.registerLanguage("yaml", yaml);
  hljs.registerLanguage("yml", yaml);
  hljs.registerLanguage("mermaid", markdown);
}

function requirePreviewRoot(): HTMLElement {
  const root = document.getElementById("preview-root");
  if (!root) {
    throw new Error("Missing preview root");
  }
  return root;
}

function initializeMermaid(theme: string): void {
  mermaid.initialize({
    startOnLoad: false,
    securityLevel: "strict",
    theme: theme === "dark" ? "dark" : "default",
  });
}
