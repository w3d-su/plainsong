import { describe, expect, it } from "vitest";
import bundleJS from "../../App/Resources/preview/bundle.js?raw";
import fontManifest from "../../App/Resources/preview/font-manifest.json?raw";
import mermaidJS from "../../App/Resources/preview/mermaid.js?raw";

// Checks the committed build output in App/Resources/preview (agent.md §7.4).
describe("committed preview bundle", () => {
  it("keeps Mermaid out of the start-up bundle", () => {
    // Every WebView parses bundle.js at start-up; Mermaid (~3.4 MB) loads on demand
    // from mermaid.js. A bundle.js near the old 4 MB means Mermaid crept back in.
    expect(new TextEncoder().encode(bundleJS).length).toBeLessThan(1_000_000);
    expect(mermaidJS).toMatch(/^"use strict";var PlainsongMermaid=/);
  });

  it("references only the woff2 KaTeX fonts the export manifest lists", () => {
    const manifest = JSON.parse(fontManifest) as { format: string; files: string[] };
    // Vitest does not process CSS, so `bundle.css?raw` is empty here; bundle.js embeds
    // the same stylesheet text for static export (`__PLAINSONG_BUNDLED_CSS__`).
    const referenced = [...bundleJS.matchAll(/url\(fonts\/([^)]+)\)/g)].map((match) => match[1]);

    expect(manifest.format).toBe("woff2");
    expect(manifest.files.length).toBeGreaterThan(0);
    expect(manifest.files.every((name) => name.endsWith(".woff2"))).toBe(true);
    expect([...new Set(referenced)].sort()).toEqual(manifest.files);
  });
});
