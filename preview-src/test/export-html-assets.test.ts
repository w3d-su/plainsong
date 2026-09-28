import { describe, expect, it } from "vitest";
import {
  EXPORT_IMAGE_SIZE_LIMIT_REASON,
  applySerializedImageBudget,
  collectFontResources,
  embedFontSources,
  utf8ByteLength,
} from "../src/export-html-assets";
import {
  EXPORT_CSP,
  MAXIMUM_EXPORT_HTML_UTF8_BYTES,
  buildStaticExportHTML,
  handleExportHTML,
  resetExportHTMLSession,
  sanitizeStaticClone,
} from "../src/export-html";

describe("export URL sinks", () => {
  it("keeps manifest font data and generated fragments, and drops other URL sinks", () => {
    const root = document.createElement("main");
    root.innerHTML = `
      <a href="https://example.com/docs">docs</a>
      <a href="mailto:author@example.com">mail</a>
      <a href="#heading">jump</a>
      <a href="javascript:alert(1)">bad</a>
      <a href="file:///tmp/secret">file</a>
      <a href="asset://photo.png">asset</a>
      <img src="data:image/png;base64,AAAA" srcset="https://evil.example/a.png 2x">
      <svg><image href="https://evil.example/a.png"></image></svg>
      <span class="katex"><svg><use href="#glyph"></use><image href="https://evil.example/x.png"></image></svg></span>
      <div class="mermaid-rendered"><svg><use xlink:href="#paint0"></use></svg></div>
      <form action="https://evil.example/post"></form>
      <video poster="https://evil.example/p.png"></video>
    `;
    sanitizeStaticClone(root, new Set(["data:font/woff2;base64,AA=="]));

    expect(root.querySelector("a[href='https://example.com/docs']")).not.toBeNull();
    expect(root.querySelector("a[href='mailto:author@example.com']")).not.toBeNull();
    expect(root.querySelector("a[href='#heading']")).not.toBeNull();
    expect(root.querySelector("a[href^='javascript']")).toBeNull();
    expect(root.querySelector("a[href^='file:']")).toBeNull();
    expect(root.querySelector("a[href^='asset:']")).toBeNull();
    expect(root.querySelector("img")?.hasAttribute("srcset")).toBe(false);
    expect(root.querySelector("main > svg, :scope > svg")).toBeNull();
    expect(root.querySelector(".katex use")?.getAttribute("href")).toBe("#glyph");
    expect(root.querySelector(".katex image")?.hasAttribute("href")).toBe(false);
    expect(root.querySelector(".mermaid-rendered use")?.getAttribute("xlink:href")).toBe("#paint0");
    expect(root.querySelector("form")).toBeNull();
    expect(root.querySelector("video")?.hasAttribute("poster")).toBe(false);
    expect(root.innerHTML).not.toContain("https://evil.example");
    expect(root.innerHTML).not.toContain("asset://");
    expect(root.innerHTML).not.toContain("file:");
  });

  it("embeds only manifest font data URIs and strips user font URLs", () => {
    const css = `
      @font-face { src: url(fonts/KaTeX_Main-Regular.woff2) format("woff2"), url(fonts/KaTeX_Main-Regular.woff) format("woff"); }
      .stolen { background: url("https://evil.example/font.woff2"); }
      .user { src: url("data:font/woff2;base64,EVIL"); }
    `;
    const descriptors = collectFontResources(css);
    expect(descriptors.map((resource) => resource.src)).toEqual([
      "fonts/KaTeX_Main-Regular.woff2",
      "fonts/KaTeX_Main-Regular.woff",
      "https://evil.example/font.woff2",
    ]);
    const known = descriptors.filter((resource) => resource.src.endsWith(".woff2") && resource.src.startsWith("fonts/"));
    const embedded = embedFontSources(css, descriptors, known.map((resource) => ({
      resourceID: resource.resourceID,
      kind: "font" as const,
      action: "embed" as const,
      dataURI: "data:font/woff2;base64,AA==",
    })));
    const root = document.createElement("main");
    const style = document.createElement("style");
    style.textContent = embedded.css;
    root.append(style);
    sanitizeStaticClone(root, embedded.allowedFontDataURIs);
    const sanitized = root.querySelector("style")?.textContent ?? "";
    expect(sanitized).toContain("data:font/woff2;base64,AA==");
    expect(sanitized).not.toContain("fonts/KaTeX");
    expect(sanitized).not.toContain("https://evil.example");
    expect(sanitized).not.toContain("EVIL");
  });
});

describe("export serialized image budget", () => {
  it("accepts an HTML document of exactly 64 MiB and fails one extra byte", () => {
    const shell = buildStaticExportHTML({
      bodyHTML: "",
      frozenTheme: "light",
      styleText: "",
      title: "T",
    });
    if (!("html" in shell)) throw new Error("expected shell");
    const room = MAXIMUM_EXPORT_HTML_UTF8_BYTES - utf8ByteLength(shell.html);
    const exact = buildStaticExportHTML({
      bodyHTML: "a".repeat(room),
      frozenTheme: "light",
      styleText: "",
      title: "T",
    });
    const over = buildStaticExportHTML({
      bodyHTML: "a".repeat(room + 1),
      frozenTheme: "light",
      styleText: "",
      title: "T",
    });
    expect("html" in exact && utf8ByteLength(exact.html)).toBe(MAXIMUM_EXPORT_HTML_UTF8_BYTES);
    expect(over).toEqual({ failed: "html-too-large" });
  });

  it("omits the image that crosses the serialized cap and still keeps a later smaller one", () => {
    const placeholder = (label: string) => {
      const span = document.createElement("span");
      span.className = "export-image-placeholder";
      span.setAttribute("role", "img");
      span.setAttribute("aria-label", label);
      span.textContent = label;
      return span.outerHTML;
    };
    const large = `data:image/png;base64,${"A".repeat(80)}`;
    const small = "data:image/png;base64,AAAA";
    const largeImage = document.createElement("img");
    largeImage.alt = "big";
    largeImage.src = large;
    const smallImage = document.createElement("img");
    smallImage.alt = "small";
    smallImage.src = small;
    const base = utf8ByteLength(placeholder("big") + placeholder("small"));
    const smallDelta = utf8ByteLength(smallImage.outerHTML) - utf8ByteLength(placeholder("small"));
    const largeDelta = utf8ByteLength(largeImage.outerHTML) - utf8ByteLength(placeholder("big"));
    const limit = base + Math.max(smallDelta, 0);
    expect(largeDelta).toBeGreaterThan(Math.max(smallDelta, 0));
    const root = document.createElement("main");
    root.innerHTML = `<img alt="big"><img alt="small">`;
    const budget = applySerializedImageBudget({
      clone: root,
      outcomes: [
        { resourceID: "image-0", kind: "image", action: "embed", dataURI: large },
        { resourceID: "image-1", kind: "image", action: "embed", dataURI: small },
      ],
      measure: (bodyHTML) => utf8ByteLength(bodyHTML),
      limit,
    });

    expect(budget.status).toBe("ok");
    expect(budget.byteLength).toBeLessThanOrEqual(limit);
    expect(root.querySelector("img")?.getAttribute("src")).toBe(small);
    expect(root.querySelector(".export-image-placeholder")?.textContent).toBe(
      EXPORT_IMAGE_SIZE_LIMIT_REASON,
    );
    expect(root.innerHTML).not.toContain(large);
    expect(utf8ByteLength(largeImage.outerHTML)).toBeGreaterThan(utf8ByteLength(smallImage.outerHTML));
  });

  it("fails closed when the document without images does not fit", () => {
    const root = document.createElement("main");
    root.innerHTML = `<p>body</p><img alt="" src="asset://a.png">`;
    const budget = applySerializedImageBudget({
      clone: root,
      outcomes: [{
        resourceID: "image-0",
        kind: "image",
        action: "embed",
        dataURI: "data:image/png;base64,AAAA",
      }],
      measure: () => null,
    });
    expect(budget.status).toBe("base-too-large");
    expect(root.querySelector("img")).toBeNull();
  });
});

describe("export readiness barrier", () => {
  it("does not emit ready before image decode resolves", async () => {
    resetExportHTMLSession();
    const root = document.createElement("main");
    root.innerHTML = `<img alt="pixel" src="asset://pixel.png">`;
    const results: string[] = [];
    let decoded = false;
    const host = {
      previewRoot: root,
      latestRenderID: 3,
      documentTheme: "light",
      collectStyleText: () => "",
      waitForFonts: async () => {},
      waitForImages: async () => {
        decoded = true;
        throw new Error("image-undecoded");
      },
      postResult: (payload: { state: { kind: string } }) => {
        results.push(payload.state.kind);
      },
    };
    await handleExportHTML(
      { exportID: 1, renderID: 3, phase: "discovery", resourceOutcomes: [], documentTitle: null },
      host,
    );
    await handleExportHTML(
      {
        exportID: 1,
        renderID: 3,
        phase: "finalization",
        documentTitle: null,
        resourceOutcomes: [{
          resourceID: "image-0",
          kind: "image",
          action: "embed",
          dataURI: "data:image/png;base64,AAAA",
        }],
      },
      host,
    );
    expect(decoded).toBe(true);
    expect(results).toEqual(["resourcesNeeded", "failed"]);
    expect(root.innerHTML).not.toContain("<script");
  });

  it("emits the exact export CSP", () => {
    const built = buildStaticExportHTML({
      bodyHTML: "<p>Body</p>",
      frozenTheme: "light",
      styleText: "",
      title: "Title",
    });
    if (!("html" in built)) throw new Error("expected html");
    expect(built.html).toContain(`content="${EXPORT_CSP}"`);
  });
});
