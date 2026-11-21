import { describe, expect, it } from "vitest";
import { applyMermaidBlockOutcome, markMermaidWrapperPending, MERMAID_SECURE_KEYS } from "../src/mermaid-renderer";
import { sanitizedMermaidCSS, sanitizedMermaidNodes } from "../src/mermaid-sanitize";

function sanitized(svg: string): HTMLElement {
  const host = document.createElement("div");
  host.replaceChildren(...sanitizedMermaidNodes(svg));
  return host;
}

describe("Mermaid output sanitizing", () => {
  it("locks themeCSS against diagram directives", () => {
    expect(MERMAID_SECURE_KEYS).toContain("themeCSS");
    expect(MERMAID_SECURE_KEYS).toContain("securityLevel");
  });

  it("removes images, form controls and scripts from a foreignObject label", () => {
    const host = sanitized(
      '<svg id="m"><g><foreignObject><div xmlns="http://www.w3.org/1999/xhtml">' +
        '<span class="nodeLabel">ok</span>' +
        '<img src="https://evil.example/a.png">' +
        '<img src="data:image/svg+xml,%3Csvg/%3E">' +
        '<form action="https://evil.example"><input type="checkbox" data-task-checkbox="true"><button>Save</button></form>' +
        "<script>alert(1)</script>" +
        '</div></foreignObject><image href="https://evil.example/b.png"/></g></svg>',
    );
    expect(host.querySelector("img, image, form, input, button, script")).toBeNull();
    expect(host.querySelector(".nodeLabel")?.textContent).toBe("ok");
    expect(host.innerHTML).not.toContain("evil.example");
  });

  it("removes the preview's own classes, attributes and event handlers", () => {
    const host = sanitized(
      '<svg><g class="node mermaid-pending mdx-error-banner task-list-item" data-line="3" ' +
        'data-task-checkbox="true" data-mermaid-source="x" onclick="alert(1)" data-id="a"></g></svg>',
    );
    const group = host.querySelector("g")!;
    expect(group.getAttribute("class")).toBe("node");
    expect(group.getAttributeNames().sort()).toEqual(["class", "data-id"]);
  });

  it("keeps fragment references and drops external ones", () => {
    const host = sanitized(
      '<svg><path id="p" marker-end="url(#arrow)" fill="url(https://evil.example/f)" style="stroke:red"/>' +
        '<rect style="background:url(https://evil.example/r)"/>' +
        '<use href="#p"/><use href="https://evil.example/x.svg#a"/>' +
        '<a href="javascript:alert(1)">j</a><a href="https://example.com/">h</a></svg>',
    );
    const path = host.querySelector("path")!;
    expect(path.getAttribute("marker-end")).toBe("url(#arrow)");
    expect(path.getAttribute("style")).toBe("stroke:red");
    expect(path.hasAttribute("fill")).toBe(false);
    expect(host.querySelector("rect")!.hasAttribute("style")).toBe(false);
    expect([...host.querySelectorAll("use")].map((use) => use.getAttribute("href"))).toEqual(["#p", null]);
    expect([...host.querySelectorAll("a")].map((a) => a.getAttribute("href"))).toEqual([null, "https://example.com/"]);
  });

  it("removes resource loads from the diagram stylesheet", () => {
    const css = sanitizedMermaidCSS(
      '@import url("https://evil.example/a.css");#m .node{fill:url(#grad);stroke:#333}' +
        '.evil{background-image:url("https://evil.example/a.png")}' +
        ".e2{background:\\75rl(https://evil.example/b.png)}" +
        '.e3{background:image-set("https://evil.example/c.png" 1x)}' +
        '@font-face{font-family:x;src:url(https://evil.example/f.woff2)}',
    );
    expect(css).not.toMatch(/url\((?!#)|image-set|@import|@font-face/i);
    expect(css).toContain("#m .node{fill:url(#grad);stroke:#333}");

    const host = sanitized('<svg><style>.x{background:url(https://evil.example/a.png)}</style></svg>');
    expect(host.querySelector("style")!.textContent).toBe(".x{background:none}");
  });

  it("sanitizes a rendered diagram before it enters the wrapper", () => {
    const wrapper = document.createElement("div");
    const descriptor = { source: "flowchart TD", ordinal: 0, themeGeneration: 1 };
    markMermaidWrapperPending(wrapper, descriptor);
    const applied = applyMermaidBlockOutcome(wrapper, descriptor, {
      kind: "success",
      fromCache: false,
      svg: '<svg id="d"><foreignObject><img src="https://evil.example/a.png"><p>label</p></foreignObject></svg>',
    });
    expect(applied).toBe(true);
    expect(wrapper.querySelector("img")).toBeNull();
    expect(wrapper.querySelector("svg p")?.textContent).toBe("label");
  });
});
