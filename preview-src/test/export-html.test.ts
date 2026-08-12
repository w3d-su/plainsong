import { afterEach, describe, expect, it } from "vitest";
import {
  EXPORT_CSP,
  EXPORT_IMAGE_PLACEHOLDER_LABEL,
  applyResourceOutcomes,
  buildStaticExportHTML,
  collectImageResources,
  freezeExportTheme,
  handleExportHTML,
  isExportBlocked,
  resetExportHTMLSessionForTests,
  sanitizeStaticClone,
  sanitizeStyleText,
} from "../src/export-html";
import { renderMarkdown, renderMdx } from "../src/pipeline";

afterEach(() => {
  resetExportHTMLSessionForTests();
});

function previewRoot(html: string, extraClass?: string): HTMLElement {
  const root = document.createElement("main");
  root.id = "preview-root";
  if (extraClass) root.className = extraClass;
  root.innerHTML = html;
  return root;
}

describe("export HTML static semantics", () => {
  it("builds a complete document with the export CSP and no runtime script", () => {
    const built = buildStaticExportHTML({
      bodyHTML: "<h1>Title</h1><p>Body</p>",
      frozenTheme: "dark",
      styleText: "body { color: red; } @font-face { src: url(fonts/KaTeX.woff2); }",
      title: "Title",
    });

    expect("html" in built).toBe(true);
    if (!("html" in built)) return;

    expect(built.html.startsWith("<!DOCTYPE html>")).toBe(true);
    expect(built.html).toContain("<html data-theme=\"dark\">");
    expect(built.html).toContain(`content="${EXPORT_CSP}"`);
    expect(built.html).toContain("<title>Title</title>");
    expect(built.html).toContain('<main id="preview-root">');
    expect(built.html).toContain("<h1>Title</h1>");
    expect(built.html).not.toContain("<script");
    expect(built.html).not.toContain("bundle.js");
    expect(built.html).toContain("url()");
    expect(built.html).not.toContain("fonts/KaTeX.woff2");
  });

  it("freezes system to a concrete light or dark theme", () => {
    expect(freezeExportTheme("light")).toBe("light");
    expect(freezeExportTheme("dark")).toBe("dark");
    expect(["light", "dark"]).toContain(freezeExportTheme("system"));
  });

  it("omits unresolved images and strips runtime behavior", () => {
    const root = previewRoot(`
      <p>
        <img src="asset://images/photo.png" alt="" onclick="alert(1)">
        <a href="javascript:alert(1)">bad</a>
        <a href="https://example.com">ok</a>
        <input type="checkbox" data-task-checkbox="true">
        <script>window.x = 1</script>
      </p>
    `);

    const resources = collectImageResources(root);
    expect(resources).toEqual([
      { resourceID: "image-0", kind: "image", src: "asset://images/photo.png" },
    ]);

    applyResourceOutcomes(root, []);
    sanitizeStaticClone(root);

    expect(root.querySelector("img")).toBeNull();
    expect(root.querySelector("script")).toBeNull();
    const placeholder = root.querySelector(".export-image-placeholder");
    expect(placeholder?.getAttribute("aria-label")).toBe(EXPORT_IMAGE_PLACEHOLDER_LABEL);
    expect(root.querySelector("a[href='https://example.com']")).not.toBeNull();
    expect(root.querySelector("a[href^='javascript']")).toBeNull();
    expect(root.querySelector<HTMLInputElement>("input")?.disabled).toBe(true);
    expect(root.querySelector("input")?.hasAttribute("data-task-checkbox")).toBe(false);
  });

  it("does not treat a pending mermaid or stale MDX tree as export-ready", () => {
    const stale = previewRoot("<p>old</p>", "preview-stale");
    const pending = previewRoot('<div class="mermaid-rendered mermaid-pending"></div>');
    expect(isExportBlocked(stale)).toBe("mdx-stale-or-error");
    expect(isExportBlocked(pending)).toBe("mermaid-pending");
  });

  it("strips frontmatter from the markdown body used for export", async () => {
    const html = await renderMarkdown(`---
title: Hidden From Export
---

# Visible Heading
`);
    expect(html).toContain("Visible Heading");
    expect(html).not.toContain("Hidden From Export");
  });

  it("keeps MDX placeholders and does not execute components", async () => {
    const html = await renderMdx(`import Button from "./Button"

<Button tone="info">**Child**</Button>
`);
    const built = buildStaticExportHTML({
      bodyHTML: html,
      frozenTheme: "light",
      styleText: "",
      title: "MDX",
    });
    expect("html" in built).toBe(true);
    if (!("html" in built)) return;
    expect(built.html).toContain("mdx-esm-placeholder");
    expect(built.html).toContain("mdx-component-card");
    expect(built.html).not.toContain("<script");
  });

  it("refuses ready before a matching finalization round", async () => {
    const results: string[] = [];
    const root = previewRoot("<h1>Hello</h1>");
    const host = {
      previewRoot: root,
      latestRenderID: 4,
      documentTheme: "light",
      collectStyleText: () => "",
      waitForFonts: async () => {},
      postResult: (payload: { state: { kind: string } }) => {
        results.push(payload.state.kind);
      },
    };

    await handleExportHTML(
      { exportID: 1, renderID: 4, phase: "finalization", resourceOutcomes: [] },
      host,
    );
    expect(results).toEqual(["failed"]);

    await handleExportHTML(
      { exportID: 2, renderID: 4, phase: "discovery", resourceOutcomes: [] },
      host,
    );
    expect(results).toEqual(["failed", "resourcesNeeded"]);

    await handleExportHTML(
      { exportID: 2, renderID: 4, phase: "finalization", resourceOutcomes: [] },
      host,
    );
    expect(results).toEqual(["failed", "resourcesNeeded", "ready"]);
  });

  it("fails a stale renderID without emitting ready HTML", async () => {
    const kinds: string[] = [];
    await handleExportHTML(
      { exportID: 9, renderID: 1, phase: "discovery", resourceOutcomes: [] },
      {
        previewRoot: previewRoot("<h1>Hello</h1>"),
        latestRenderID: 2,
        documentTheme: "light",
        collectStyleText: () => "",
        waitForFonts: async () => {},
        postResult: (payload) => {
          kinds.push(payload.state.kind);
        },
      },
    );
    expect(kinds).toEqual(["failed"]);
  });

  it("fails current MDX error/stale DOM instead of exporting last-good content", async () => {
    const kinds: string[] = [];
    const root = previewRoot("<p>last good</p>", "preview-stale");
    const banner = document.createElement("aside");
    banner.className = "mdx-error-banner";
    root.prepend(banner);

    await handleExportHTML(
      { exportID: 3, renderID: 8, phase: "discovery", resourceOutcomes: [] },
      {
        previewRoot: root,
        latestRenderID: 8,
        documentTheme: "light",
        collectStyleText: () => "",
        waitForFonts: async () => {},
        postResult: (payload) => {
          kinds.push(payload.state.kind);
        },
      },
    );
    expect(kinds).toEqual(["failed"]);
  });
});

describe("export style URL sinks", () => {
  it("keeps font data URIs and same-document fragments", () => {
    const css = `
      @font-face { src: url("data:font/woff2;base64,AA=="); }
      .icon { background: url(#paint0); }
      .remote { background: url("https://evil.example/x.png"); }
    `;
    const sanitized = sanitizeStyleText(css);
    expect(sanitized).toContain("data:font/woff2;base64,AA==");
    expect(sanitized).toContain("url(#paint0)");
    expect(sanitized).not.toContain("https://evil.example/x.png");
  });
});
