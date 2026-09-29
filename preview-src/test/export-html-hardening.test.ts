import { afterEach, describe, expect, it } from "vitest";
import type { ExportHTMLPayload, ExportHTMLResultPayload, ExportResourceOutcome } from "../src/bridge";
import {
  EXPORT_IMAGE_SIZE_LIMIT_REASON,
  type ExportHTMLHost,
  handleExportHTML,
  resetExportHTMLSession,
  sanitizeStaticClone,
  sanitizeStyleText,
} from "../src/export-html";

afterEach(() => { resetExportHTMLSession(); });

const pngA = "data:image/png;base64,QUFBQQ==";
const pngB = "data:image/png;base64,QkJCQg==";

function fixture(html: string, overrides: Partial<ExportHTMLHost> = {}) {
  const root = document.createElement("main");
  root.innerHTML = html;
  const results: ExportHTMLResultPayload[] = [];
  const host: ExportHTMLHost = {
    previewRoot: root, latestRenderID: 5, documentTheme: "light",
    collectStyleText: () => "", waitForFonts: async () => {},
    postResult: (result) => results.push(result),
    ...overrides,
  };
  const payload: ExportHTMLPayload = {
    exportID: 1, renderID: 5, phase: "discovery", resourceOutcomes: [], documentTitle: null,
  };
  return { root, host, results, payload };
}

async function exportWith(
  html: string,
  outcomes: ExportResourceOutcome[],
  overrides: Partial<ExportHTMLHost> = {},
) {
  const context = fixture(html, overrides);
  await handleExportHTML(context.payload, context.host);
  await handleExportHTML({ ...context.payload, phase: "finalization", resourceOutcomes: outcomes }, context.host);
  const state = context.results.at(-1)!.state;
  const doc = state.kind === "ready" ? new DOMParser().parseFromString(state.html, "text/html") : null;
  return { ...context, state, doc };
}

function embed(resourceID: string, dataURI: string, kind: "image" | "font" = "image"): ExportResourceOutcome {
  return { resourceID, kind, action: "embed", dataURI };
}

describe("export review fixes", () => {
  it("numbers bundled and inline font resources without ID collisions (finding 1)", async () => {
    const bundled = "@font-face{font-family:A;src:url(fonts/A.woff2)}";
    const inline = "@font-face{font-family:B;src:url(fonts/B.woff2)}";
    const { results, state } = await exportWith(
      `<p>fonts</p><style>${inline}</style>`,
      [embed("font-0", "data:font/woff2;base64,QUFB", "font"), embed("font-1", "data:font/woff2;base64,QkJC", "font")],
      { bundledStyleText: bundled, collectStyleText: () => `${bundled}\n${inline}` },
    );
    const discovered = results[0]!.state;
    if (discovered.kind !== "resourcesNeeded") throw new Error("expected discovery");
    expect(discovered.resources.map((resource) => [resource.resourceID, resource.src])).toEqual([
      ["font-0", "fonts/A.woff2"],
      ["font-1", "fonts/B.woff2"],
    ]);
    if (state.kind !== "ready") throw new Error(`expected ready, got ${state.kind}`);
    expect(state.html).toContain('font-family:A;src:url("data:font/woff2;base64,QUFB")');
    expect(state.html).toContain('font-family:B;src:url("data:font/woff2;base64,QkJC")');
  });

  it("resolves a repeated image through dataURIFrom and fails closed on bad references (finding 2)", async () => {
    const { doc } = await exportWith(
      '<img alt="a"><img alt="b"><img alt="c"><img alt="d"><img alt="e">',
      [
        embed("image-0", pngA),
        { resourceID: "image-1", kind: "image", action: "embed", dataURIFrom: "image-0" },
        { resourceID: "image-2", kind: "image", action: "embed", dataURIFrom: "image-4" },
        { resourceID: "image-3", kind: "image", action: "embed", dataURI: pngB, dataURIFrom: "image-0" },
        { resourceID: "image-4", kind: "image", action: "embed", dataURIFrom: "image-1" },
      ],
    );
    expect(Array.from(doc!.querySelectorAll("img"), (image) => image.getAttribute("src"))).toEqual([pngA, pngA]);
    expect(Array.from(doc!.querySelectorAll(".export-image-placeholder"), (span) => span.textContent))
      .toEqual(["c", "d", "e"]);
  });

  it("fails closed when finalization sees a different image DOM than discovery (finding 3)", async () => {
    for (const mutate of [
      (root: HTMLElement) => root.querySelector("img")!.setAttribute("src", "asset://b.png"),
      (root: HTMLElement) => root.append(root.ownerDocument.createElement("img")),
    ]) {
      const { root, host, results, payload } = fixture('<img alt="a" src="asset://a.png">');
      await handleExportHTML(payload, host);
      mutate(root);
      await handleExportHTML({ ...payload, phase: "finalization", resourceOutcomes: [embed("image-0", pngA)] }, host);
      expect(results.at(-1)!.state).toEqual({ kind: "failed", reason: "resources-changed" });
      expect(root.innerHTML).not.toContain(pngA);
      resetExportHTMLSession();
    }
  });

  it("turns an undecodable image into its placeholder and still exports (finding 4)", async () => {
    const { state, doc } = await exportWith(
      '<img alt="broken" src="asset://a.png"><img alt="good" src="asset://b.png">',
      [embed("image-0", pngA), embed("image-1", pngB)],
      { decodeImage: async (dataURI) => dataURI !== pngA },
    );
    expect(state.kind).toBe("ready");
    expect(doc!.querySelector("img")!.getAttribute("src")).toBe(pngB);
    expect(doc!.querySelector(".export-image-placeholder")!.getAttribute("aria-label")).toBe("broken");
  });

  it("never posts ready while a retained image decode is pending (finding 4)", async () => {
    let release!: (decoded: boolean) => void;
    const pending = new Promise<boolean>((resolve) => { release = resolve; });
    const { host, results, payload } = fixture('<img alt="slow" src="asset://a.png">', {
      decodeImage: () => pending,
    });
    await handleExportHTML(payload, host);
    const finalization = handleExportHTML(
      { ...payload, phase: "finalization", resourceOutcomes: [embed("image-0", pngA)] },
      host,
    );
    for (let tick = 0; tick < 20; tick += 1) await Promise.resolve();
    expect(results.map((result) => result.state.kind)).toEqual(["resourcesNeeded"]);
    release(true);
    await finalization;
    const state = results.at(-1)!.state;
    expect(state.kind).toBe("ready");
    if (state.kind === "ready") expect(state.html).toContain(pngA);
  });

  it.each([
    ['@import "https://evil.example/a.css"; .a { color: red; }', ".a { color: red; }"],
    ["@\\69mport url(https://evil.example/b.css); .b { color: red; }", ".b { color: red; }"],
    ['.c { background: image-set("https://evil.example/c.png" 1x); }', ".c { background: none; }"],
    [".d { background: -webkit-image-set(url(https://evil.example/d.png) 1x); }", ".d { background: none; }"],
    [".e { background: u\\72l(https://evil.example/e.png); }", ".e { background: url(); }"],
    ['.f { background: url("https://evil.example/f.png?)"); }', ".f { background: url(); }"],
    [".g { background: url('https://evil.example/g\"x'); }", ".g { background: url(); }"],
    [".h { background: url(https://evil.example/h.png", ".h { background: url()"],
    [".i { background: URL(  https://evil.example/i.png  ); }", ".i { background: url(); }"],
    [".j { background: url(https://evil.example/j.png\\)x); }", ".j { background: url(); }"],
  ])("fails closed on the CSS URL sink %s (finding 5)", (css, expected) => {
    const sanitized = sanitizeStyleText(css, new Set());
    expect(sanitized).not.toContain("evil.example");
    expect(sanitized.trim()).toBe(expected);
  });

  it("keeps allowed fragments and manifest fonts through the CSS scanner (finding 5)", () => {
    const font = "data:font/woff2;base64,QUFB";
    const css = `.k { fill: url(#paint0); filter: url('#glow'); } @font-face { src: url(${font}) format("woff2"); }`;
    expect(sanitizeStyleText(css, new Set([font]))).toBe(
      `.k { fill: url("#paint0"); filter: url("#glow"); } @font-face { src: url("${font}") format("woff2"); }`,
    );
    expect(sanitizeStyleText('.l { fill: url("#a) , url(https://evil.example/x"); }', new Set()))
      .toBe(".l { fill: url(); }");
  });

  it("sanitizes SVG style and presentation attributes in generated SVG (finding 5)", () => {
    const root = document.createElement("main");
    root.innerHTML = `<div class="mermaid-rendered"><svg>
      <path style="fill:url(https://evil.example/a.png)" fill="u\\72l(https://evil.example/b.png)"
        marker-end="url(#mermaid-0-1_flowchart-v2-pointEnd)"></path>
      <style>.node{fill:url(https://evil.example/c.png)}</style>
    </svg></div>`;
    sanitizeStaticClone(root);
    expect(root.innerHTML).not.toContain("evil.example");
    expect(root.querySelector("path")!.getAttribute("marker-end"))
      .toBe('url("#mermaid-0-1_flowchart-v2-pointEnd")');
  });

  it("uses the placeholder for an image without a validated outcome (finding 6)", async () => {
    const { doc, root } = await exportWith(`<img alt="inline" src="${pngA}">`, []);
    expect(doc!.querySelector("img")).toBeNull();
    expect(doc!.querySelector(".export-image-placeholder")!.textContent).toBe("inline");
    expect(root.innerHTML).not.toContain(pngA);
  });

  it("measures the sanitized document so the budget matches the final HTML (finding 7)", async () => {
    const body = `<p><input type="checkbox"><input type="checkbox"></p><style>.x::after{content:"<<<<"}</style>
      <img alt="i" src="asset://a.png">`;
    // Larger than its size-limit placeholder, so omitting it shrinks the document.
    const large = `data:image/png;base64,${"QUFB".repeat(100)}`;
    const outcomes = [embed("image-0", large)];
    const unlimited = await exportWith(body, outcomes);
    if (unlimited.state.kind !== "ready") throw new Error("expected ready");
    const exact = new TextEncoder().encode(unlimited.state.html).length;

    const atLimit = await exportWith(body, outcomes, { maximumHTMLUTF8Bytes: exact });
    expect(atLimit.state.kind).toBe("ready");
    expect(atLimit.doc!.querySelector("img")!.getAttribute("src")).toBe(large);

    const belowLimit = await exportWith(body, outcomes, { maximumHTMLUTF8Bytes: exact - 1 });
    expect(belowLimit.state.kind).toBe("ready");
    if (belowLimit.state.kind !== "ready") return;
    expect(new TextEncoder().encode(belowLimit.state.html).length).toBeLessThanOrEqual(exact - 1);
    expect(belowLimit.doc!.querySelector("img")).toBeNull();
    expect(belowLimit.doc!.querySelector(".export-image-placeholder")!.textContent)
      .toBe(EXPORT_IMAGE_SIZE_LIMIT_REASON);
  });

  it("leaves the live preview untouched after a superseded or failed finalization (finding 8)", async () => {
    for (const overrides of [
      { waitForFonts: async () => { resetExportHTMLSession(); } },
      { maximumHTMLUTF8Bytes: 10 },
    ] satisfies Partial<ExportHTMLHost>[]) {
      const { root, host, results, payload } = fixture('<p>live</p><img alt="x" src="asset://x.png">', overrides);
      const nodes = Array.from(root.childNodes);
      const html = root.innerHTML;
      await handleExportHTML(payload, host);
      await handleExportHTML({ ...payload, phase: "finalization" }, host);
      expect(results.at(-1)!.state.kind).toBe("failed");
      expect(root.innerHTML).toBe(html);
      expect(Array.from(root.childNodes).every((node, index) => node === nodes[index])).toBe(true);
      resetExportHTMLSession();
    }
  });

  it("indexes outcomes once and fails closed on duplicate resource IDs (finding 10)", async () => {
    const { doc } = await exportWith(
      '<img alt="twice" src="asset://a.png"><img alt="once" src="asset://b.png">',
      [embed("image-0", pngA), embed("image-0", pngB), embed("image-1", pngB)],
    );
    expect(Array.from(doc!.querySelectorAll("img"), (image) => image.getAttribute("src"))).toEqual([pngB]);
    expect(doc!.querySelector(".export-image-placeholder")!.textContent).toBe("twice");
  });
});
