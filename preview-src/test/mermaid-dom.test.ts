import { describe, expect, it, vi } from "vitest";
import {
  patchPreviewRoot,
  rerenderVisibleMermaidBlocks,
} from "../src/mermaid-dom";
import {
  type MermaidInitialization,
  MermaidRenderCoordinator,
} from "../src/mermaid-renderer";

const SOURCES = {
  first: "flowchart TD\nA --> B",
  second: "sequenceDiagram\nA->>B: Hi",
  third: "stateDiagram-v2\n[*] --> Ready",
};

function previewRoot(sources: readonly string[]): HTMLElement {
  const root = document.createElement("main");
  root.id = "preview-root";
  for (const source of sources) {
    const pre = document.createElement("pre");
    const code = document.createElement("code");
    code.className = "language-mermaid";
    code.textContent = source;
    pre.append(code);
    root.append(pre);
  }
  return root;
}

function makeRenderer(
  render = vi.fn(async (id: string, source: string) => ({
    svg: renderedSVG(id, source),
  })),
) {
  const initialize = vi.fn((_configuration: MermaidInitialization) => {});
  const coordinator = new MermaidRenderCoordinator(render, initialize);
  coordinator.initializeTheme("system");
  return { coordinator, initialize, render };
}

function renderedSVG(id: string, source: string): string {
  return (
    `<svg xmlns="http://www.w3.org/2000/svg" data-render-id="${id}" ` +
    `data-source="${encodeURIComponent(source)}"><g id="${id}-node"></g></svg>`
  );
}

function mermaidSVGs(root: HTMLElement): SVGSVGElement[] {
  return Array.from(
    root.querySelectorAll<SVGSVGElement>(".mermaid-rendered > svg"),
  );
}

describe("Mermaid preview DOM patching", () => {
  it("renders identical source once and preserves the exact SVG node", async () => {
    const { coordinator, render } = makeRenderer();
    const liveRoot = previewRoot([]);

    await patchPreviewRoot(
      liveRoot,
      previewRoot([SOURCES.first]),
      coordinator,
    );
    const originalSVG = mermaidSVGs(liveRoot)[0];

    await patchPreviewRoot(
      liveRoot,
      previewRoot([SOURCES.first]),
      coordinator,
    );

    expect(render).toHaveBeenCalledTimes(1);
    expect(mermaidSVGs(liveRoot)[0]).toBe(originalSVG);
    expect(liveRoot.contains(originalSVG)).toBe(true);
  });

  it("re-renders only one edited diagram among three", async () => {
    const { coordinator, render } = makeRenderer();
    const liveRoot = previewRoot([]);
    const initialSources = [SOURCES.first, SOURCES.second, SOURCES.third];

    await patchPreviewRoot(
      liveRoot,
      previewRoot(initialSources),
      coordinator,
    );
    const originalSVGs = mermaidSVGs(liveRoot);
    const editedSources = [
      SOURCES.first,
      "sequenceDiagram\nA->>B: Edited",
      SOURCES.third,
    ];

    await patchPreviewRoot(
      liveRoot,
      previewRoot(editedSources),
      coordinator,
    );
    const patchedSVGs = mermaidSVGs(liveRoot);

    expect(render.mock.calls.map(([, source]) => source)).toEqual([
      ...initialSources,
      editedSources[1],
    ]);
    expect(patchedSVGs[0]).toBe(originalSVGs[0]);
    expect(patchedSVGs[1]).not.toBe(originalSVGs[1]);
    expect(patchedSVGs[2]).toBe(originalSVGs[2]);
    expect(liveRoot.contains(originalSVGs[1])).toBe(false);
  });

  it("keeps equal-source diagrams distinct by ordinal", async () => {
    const { coordinator, render } = makeRenderer();
    const liveRoot = previewRoot([]);

    await patchPreviewRoot(
      liveRoot,
      previewRoot([SOURCES.first, SOURCES.first]),
      coordinator,
    );
    const renderedIDs = mermaidSVGs(liveRoot).map(
      (svg) => svg.dataset.renderId,
    );

    expect(render).toHaveBeenCalledTimes(2);
    expect(new Set(renderedIDs).size).toBe(2);
  });

  it("re-renders every visible diagram after a theme change", async () => {
    const { coordinator, initialize, render } = makeRenderer();
    const liveRoot = previewRoot([]);
    const sources = [SOURCES.first, SOURCES.second];

    await patchPreviewRoot(liveRoot, previewRoot(sources), coordinator);
    const originalSVGs = mermaidSVGs(liveRoot);

    expect(coordinator.initializeTheme("dark")).toBe(true);
    await rerenderVisibleMermaidBlocks(liveRoot, coordinator);
    const themedSVGs = mermaidSVGs(liveRoot);

    expect(render).toHaveBeenCalledTimes(4);
    expect(themedSVGs[0]).not.toBe(originalSVGs[0]);
    expect(themedSVGs[1]).not.toBe(originalSVGs[1]);
    expect(originalSVGs.every((svg) => !liveRoot.contains(svg))).toBe(true);
    expect(initialize.mock.calls).toEqual([
      [
        {
          startOnLoad: false,
          securityLevel: "strict",
          theme: "default",
        },
      ],
      [
        {
          startOnLoad: false,
          securityLevel: "strict",
          theme: "dark",
        },
      ],
    ]);
  });

  it("shows a render error and retries instead of caching the failure", async () => {
    const render = vi
      .fn<(id: string, source: string) => Promise<{ svg: string }>>()
      .mockRejectedValueOnce(new Error("bad diagram"))
      .mockImplementation(async (id, source) => ({
        svg: renderedSVG(id, source),
      }));
    const { coordinator } = makeRenderer(render);
    const liveRoot = previewRoot([]);

    await patchPreviewRoot(
      liveRoot,
      previewRoot([SOURCES.first]),
      coordinator,
    );
    const error = liveRoot.querySelector<HTMLElement>(".mermaid-error");
    expect(error?.textContent).toBe("bad diagram");
    expect(coordinator.cacheSize).toBe(0);

    await patchPreviewRoot(
      liveRoot,
      previewRoot([SOURCES.first]),
      coordinator,
    );
    expect(liveRoot.querySelector(".mermaid-error")).toBeNull();
    expect(mermaidSVGs(liveRoot)).toHaveLength(1);

    await patchPreviewRoot(
      liveRoot,
      previewRoot([SOURCES.first]),
      coordinator,
    );
    expect(render).toHaveBeenCalledTimes(2);
  });

  it("preserves unchanged highlighted non-Mermaid code DOM", async () => {
    const { coordinator, render } = makeRenderer();
    const liveRoot = document.createElement("main");
    liveRoot.innerHTML =
      '<pre><code class="language-swift hljs" data-highlighted="yes">' +
      '<span class="hljs-keyword">let</span> answer = 42;\n</code></pre>';
    const highlightedCode = liveRoot.querySelector("code");
    const highlightedSpan = liveRoot.querySelector("span");
    const nextRoot = document.createElement("main");
    nextRoot.innerHTML =
      '<pre><code class="language-swift">let answer = 42;\n</code></pre>';

    await patchPreviewRoot(liveRoot, nextRoot, coordinator);

    expect(liveRoot.querySelector("code")).toBe(highlightedCode);
    expect(liveRoot.querySelector("span")).toBe(highlightedSpan);
    expect(highlightedCode?.getAttribute("data-highlighted")).toBe("yes");
    expect(render).not.toHaveBeenCalled();
  });

  it("collects a new Mermaid wrapper inside an added nested subtree", async () => {
    const { coordinator, render } = makeRenderer();
    const liveRoot = previewRoot([]);
    const nextRoot = previewRoot([]);
    const section = document.createElement("section");
    const article = document.createElement("article");
    const diagram = previewRoot([SOURCES.first]).firstElementChild;
    if (!diagram) throw new Error("missing test diagram");
    article.append(diagram);
    section.append(article);
    nextRoot.append(section);

    await patchPreviewRoot(liveRoot, nextRoot, coordinator);

    expect(render).toHaveBeenCalledTimes(1);
    expect(mermaidSVGs(liveRoot)).toHaveLength(1);
  });

  it("invalidates shifted ordinals when a diagram is inserted above", async () => {
    const { coordinator, render } = makeRenderer();
    const liveRoot = previewRoot([]);
    const initialSources = [SOURCES.first, SOURCES.second, SOURCES.third];

    await patchPreviewRoot(
      liveRoot,
      previewRoot(initialSources),
      coordinator,
    );
    const originalSVGs = mermaidSVGs(liveRoot);
    render.mockClear();
    const insertedSources = [
      "flowchart LR\nNew --> First",
      ...initialSources,
    ];

    await patchPreviewRoot(
      liveRoot,
      previewRoot(insertedSources),
      coordinator,
    );

    expect(render.mock.calls.map(([, source]) => source)).toEqual(
      insertedSources,
    );
    expect(originalSVGs.every((svg) => !liveRoot.contains(svg))).toBe(true);
  });

  it("keeps the previous SVG visible but pending until an edit resolves", async () => {
    let resolveEdit: ((result: { svg: string }) => void) | undefined;
    const render = vi
      .fn<(id: string, source: string) => Promise<{ svg: string }>>()
      .mockImplementationOnce(async (id, source) => ({
        svg: renderedSVG(id, source),
      }))
      .mockImplementationOnce(
        () =>
          new Promise((resolve) => {
            resolveEdit = resolve;
          }),
      );
    const { coordinator } = makeRenderer(render);
    const liveRoot = previewRoot([]);

    await patchPreviewRoot(
      liveRoot,
      previewRoot([SOURCES.first]),
      coordinator,
    );
    const originalSVG = mermaidSVGs(liveRoot)[0];
    const editedSource = "flowchart TD\nA --> Edited";

    const firstEdit = patchPreviewRoot(
      liveRoot,
      previewRoot([editedSource]),
      coordinator,
    );
    const pendingWrapper = liveRoot.querySelector<HTMLElement>(
      ".mermaid-rendered",
    );
    expect(pendingWrapper?.classList.contains("mermaid-pending")).toBe(true);
    expect(pendingWrapper?.dataset.mermaidSource).toBe(editedSource);
    expect(pendingWrapper?.firstElementChild).toBe(originalSVG);
    expect(originalSVG.dataset.source).toBe(encodeURIComponent(SOURCES.first));

    const overlappingEdit = patchPreviewRoot(
      liveRoot,
      previewRoot([editedSource]),
      coordinator,
    );
    expect(render).toHaveBeenCalledTimes(2);
    expect(pendingWrapper?.classList.contains("mermaid-pending")).toBe(true);
    expect(pendingWrapper?.firstElementChild).toBe(originalSVG);
    await expect(
      Promise.race([
        overlappingEdit.then(() => "settled"),
        Promise.resolve("pending"),
      ]),
    ).resolves.toBe("pending");

    resolveEdit?.({
      svg: renderedSVG("resolved-edit", editedSource),
    });
    await Promise.all([firstEdit, overlappingEdit]);

    expect(liveRoot.contains(originalSVG)).toBe(false);
    expect(pendingWrapper?.classList.contains("mermaid-pending")).toBe(false);
    expect(mermaidSVGs(liveRoot)[0].dataset.source).toBe(
      encodeURIComponent(editedSource),
    );
  });

  it("allows namespaced SVG descendants to morph without HTML-only access", async () => {
    const { coordinator } = makeRenderer();
    const liveRoot = document.createElement("main");
    liveRoot.innerHTML =
      '<span class="katex"><svg xmlns="http://www.w3.org/2000/svg">' +
      '<path data-state="old"></path></svg></span>';
    const nextRoot = document.createElement("main");
    nextRoot.innerHTML =
      '<span class="katex"><svg xmlns="http://www.w3.org/2000/svg">' +
      '<path data-state="new"></path></svg></span>';

    await expect(
      patchPreviewRoot(liveRoot, nextRoot, coordinator),
    ).resolves.toBeUndefined();
    expect(liveRoot.querySelector("path")?.getAttribute("data-state")).toBe(
      "new",
    );
  });
});
