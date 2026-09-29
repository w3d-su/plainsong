import { afterEach, describe, expect, it } from "vitest";
import type { ExportHTMLResultPayload } from "../src/bridge";
import { rewriteCSSURLs } from "../src/export-css-urls";
import {
  buildStaticExportHTML,
  handleExportHTML,
  resetExportHTMLSession,
  sanitizeStaticClone,
  sanitizeStyleText,
} from "../src/export-html";

afterEach(() => { resetExportHTMLSession(); });

const font = "data:font/woff2;base64,QUFB";
const allowed = new Set([font]);
// Escaping `<` after the URL scan once turned `\<url(` into `\\3c url(`: an ident, then a
// real url() token.
const bypass = String.raw`li{list-style:\<url(https://evil.example/a.png)}`;
const customBypass = String.raw`li{--a:\<url(https://evil.example/b.png);list-style:var(--a)}`;

/** Every URL a CSS tokenizer would see in `css` that is not neutralized or allowlisted. */
function disallowedURLs(css: string): (string | null)[] {
  const found: (string | null)[] = [];
  rewriteCSSURLs(css, (value, raw) => {
    if (value === null || (value !== "" && !value.startsWith("#") && !allowed.has(value))) found.push(value);
    return raw;
  });
  return found;
}

function expectSafe(css: string): void {
  expect(css).not.toContain("<");
  expect(disallowedURLs(css)).toEqual([]);
  expect(sanitizeStyleText(css, allowed)).toBe(css);
}

describe("export CSS URL sinks", () => {
  it.each([bypass, customBypass])("neutralizes %s in head CSS, SVG style, and style attributes", async (css) => {
    expect(sanitizeStyleText(css, allowed)).not.toContain("evil.example");

    const root = document.createElement("main");
    const wrapper = document.createElement("div");
    wrapper.className = "mermaid-rendered";
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    const svgStyle = document.createElementNS("http://www.w3.org/2000/svg", "style");
    svgStyle.textContent = css;
    svg.append(svgStyle);
    wrapper.append(svg);
    const paragraph = document.createElement("p");
    paragraph.setAttribute("style", css.replace(/^li\{|\}$/gu, ""));
    paragraph.textContent = "styled";
    root.append(wrapper, paragraph);

    const results: ExportHTMLResultPayload[] = [];
    const host = {
      previewRoot: root, latestRenderID: 2, documentTheme: "light",
      collectStyleText: () => css, waitForFonts: async () => {},
      postResult: (result: ExportHTMLResultPayload) => results.push(result),
    };
    const payload = { exportID: 1, renderID: 2, phase: "discovery" as const, resourceOutcomes: [], documentTitle: null };
    await handleExportHTML(payload, host);
    await handleExportHTML({ ...payload, phase: "finalization" }, host);
    const state = results.at(-1)!.state;
    if (state.kind !== "ready") throw new Error(`expected ready, got ${JSON.stringify(state)}`);
    expect(state.html).not.toContain("evil.example");

    const doc = new DOMParser().parseFromString(state.html, "text/html");
    const sinks = [
      doc.head.querySelector("style")!.textContent ?? "",
      doc.querySelector(".mermaid-rendered svg style")!.textContent ?? "",
      doc.querySelector("p")!.getAttribute("style") ?? "",
    ];
    for (const sink of sinks) expectSafe(sink);
  });

  it("re-scans sanitized output and finds only allowlisted URLs across tricky inputs", () => {
    const prefixes = ["", "\\", "\\\\", "<", "\\<", "\\\\<", "/**/", "\\\n", "-", "--x:", "var(--a,", "\\3c ", "x\\"];
    const sinks = ["url", "URL", "u\\72l", "\\75rl", "u\\rl", "\\55 RL", "u\\<rl", "image-set", "im\\61ge-set", "src"];
    const argumentsList = [
      "(https://evil.example/x)",
      "(\"https://evil.example/x\")",
      "( 'https://evil.example/x' )",
      "(https://evil.example/x",
      "(\"https://evil.example/x)\")",
      "(https://evil.example/\\)x)",
      "(\"x\"\\)",
      "(<https://evil.example/x>)",
      "(/**/https://evil.example/x)",
      `(${font})`,
      "(#frag)",
    ];
    const suffixes = ["", "}", ";a:b}", "\n", ")", "\\"];
    const wrappers = [
      (value: string) => `a{background:${value}`,
      (value: string) => `a{--p:${value}`,
      (value: string) => `@media screen{a{b:${value}}}`,
    ];
    const atRules = [
      "@import url(https://evil.example/x);",
      "@\\69mport 'https://evil.example/x';",
      "@import\"https://evil.example/x\"",
      "@\\<import url(https://evil.example/x);",
      "@IMPORT url(https://evil.example/x) screen{}",
    ];

    let checked = 0;
    for (const atRule of atRules) {
      expectSafe(sanitizeStyleText(`${atRule}a{b:c}`, allowed));
      checked += 1;
    }
    for (const wrap of wrappers) {
      for (const prefix of prefixes) {
        for (const sink of sinks) {
          for (const argument of argumentsList) {
            for (const suffix of suffixes) {
              expectSafe(sanitizeStyleText(wrap(`${prefix}${sink}${argument}${suffix}`), allowed));
              checked += 1;
            }
          }
        }
      }
    }
    expect(checked).toBe(atRules.length + wrappers.length * prefixes.length * sinks.length *
      argumentsList.length * suffixes.length);
  });

  it("keeps later rules when a malformed url() or image-set() is followed by a closing brace", () => {
    for (const css of [
      String.raw`a{b:url("x"\)}c{d:e}`,
      String.raw`a{b:url(x y}c{d:e}`,
      String.raw`a{b:image-set("x" 1x}c{d:e}`,
    ]) {
      const sanitized = sanitizeStyleText(css, allowed);
      expect(sanitized).toMatch(/\}c\{d:e\}$/u);
      expectSafe(sanitized);
    }
  });

  it("still escapes closing style tags", () => {
    const root = document.createElement("main");
    const style = document.createElement("style");
    style.textContent = '.x::after{content:"</style><b>x</b>"}';
    root.append(style);
    sanitizeStaticClone(root);
    expect(root.querySelector("style")!.textContent).toBe('.x::after{content:"\\3c /style>\\3c b>x\\3c /b>"}');
    const built = buildStaticExportHTML({ bodyHTML: "", frozenTheme: "light", styleText: "a<b{}", title: "T" });
    if (!("html" in built)) throw new Error("expected html");
    expect(built.html).toContain("<style>a\\3c b{}</style>");
  });
});
