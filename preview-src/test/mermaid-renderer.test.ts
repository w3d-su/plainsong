import morphdom from "morphdom";
import { describe, expect, it, vi } from "vitest";
import { rerenderVisibleMermaidBlocks } from "../src/mermaid-dom";
import {
  applyMermaidBlockOutcome,
  MERMAID_RENDER_CACHE_CAPACITY,
  type MermaidBlockDescriptor,
  type MermaidInitialization,
  MermaidRenderCoordinator,
  markMermaidWrapperPending,
  type PreviewPatchElementLike,
  shouldUpdatePreviewElement,
} from "../src/mermaid-renderer";

class FakeClassList {
  private readonly tokens = new Set<string>();

  constructor(tokens: string[] = []) {
    for (const token of tokens) this.tokens.add(token);
  }

  add(...tokens: string[]): void {
    for (const token of tokens) this.tokens.add(token);
  }

  remove(...tokens: string[]): void {
    for (const token of tokens) this.tokens.delete(token);
  }

  contains(token: string): boolean {
    return this.tokens.has(token);
  }

  values(): string[] {
    return Array.from(this.tokens);
  }
}

class FakeNode {
  readonly id = "";
  readonly nodeType = 1;
  readonly parentNode = null;
  readonly nextSibling = null;
  firstChild: FakeNode | null = null;

  constructor(readonly nodeName: string) {}

  getAttribute(_name: string): string | null {
    return null;
  }
}

class FakeElement extends FakeNode implements PreviewPatchElementLike {
  readonly classList: FakeClassList;
  readonly dataset: Record<string, string | undefined> = {};
  readonly highlightedChild = new FakeNode("SVG");
  innerHTML = "";
  textContent: string | null;

  constructor(
    private readonly isCode: boolean,
    textContent: string | null,
    classes: string[] = [],
  ) {
    super(isCode ? "CODE" : "DIV");
    this.textContent = textContent;
    this.classList = new FakeClassList(classes);
    this.firstChild = this.highlightedChild;
  }

  get className(): string {
    return this.classList.values().join(" ");
  }

  matches(selector: string): boolean {
    return selector === "pre code" && this.isCode;
  }
}

class FakeRoot {
  constructor(private readonly wrappers: FakeElement[]) {}

  querySelectorAll(_selector: string): FakeElement[] {
    return this.wrappers;
  }

  contains(node: unknown): boolean {
    return this.wrappers.includes(node as FakeElement);
  }
}

function applyMorphdomPatch(
  fromElement: FakeElement,
  toElement: FakeElement,
): FakeElement {
  return morphdom(
    fromElement as unknown as Node,
    toElement as unknown as Node,
    { onBeforeElUpdated: shouldUpdatePreviewElement },
  ) as unknown as FakeElement;
}

function legacyDjb2Hash(value: string): string {
  let hash = 5381;
  for (let index = 0; index < value.length; index += 1) {
    hash = (hash * 33) ^ value.charCodeAt(index);
  }
  return (hash >>> 0).toString(36);
}

function makeRenderer() {
  const render = vi.fn(async (_id: string, source: string) => ({
    svg: `<svg data-source="${source}"></svg>`,
  }));
  const initialize = vi.fn((_configuration: MermaidInitialization) => {});
  const coordinator = new MermaidRenderCoordinator(render, initialize);
  coordinator.initializeTheme("system");
  return { coordinator, initialize, render };
}

function pendingWrapper(descriptor: MermaidBlockDescriptor): FakeElement {
  const wrapper = new FakeElement(false, null);
  markMermaidWrapperPending(wrapper, descriptor);
  return wrapper;
}

describe("Mermaid preview rendering", () => {
  it("renders identical source once and preserves the existing SVG DOM", async () => {
    const { coordinator, render } = makeRenderer();
    const source = "flowchart TD\nA --> B";
    const descriptor = coordinator.descriptor(source, 0);
    const firstOutcome = await coordinator.render(descriptor);
    const liveWrapper = pendingWrapper(descriptor);

    expect(applyMermaidBlockOutcome(liveWrapper, descriptor, firstOutcome)).toBe(
      true,
    );
    const liveSVG = liveWrapper.highlightedChild;

    const secondOutcome = await coordinator.render(
      coordinator.descriptor(source, 0),
    );
    const nextWrapper = pendingWrapper(coordinator.descriptor(source, 0));
    const patchedWrapper = applyMorphdomPatch(liveWrapper, nextWrapper);

    expect(secondOutcome).toMatchObject({
      kind: "success",
      fromCache: true,
    });
    expect(render).toHaveBeenCalledTimes(1);
    expect(patchedWrapper).toBe(liveWrapper);
    expect(patchedWrapper.highlightedChild).toBe(liveSVG);
  });

  it("re-renders only the edited diagram", async () => {
    const { coordinator, render } = makeRenderer();
    const firstSources = ["flowchart TD\nA --> B", "sequenceDiagram\nA->>B: Hi"];

    for (const [ordinal, source] of firstSources.entries()) {
      await coordinator.render(coordinator.descriptor(source, ordinal));
    }

    const editedSources = ["flowchart TD\nA --> C", firstSources[1]];
    for (const [ordinal, source] of editedSources.entries()) {
      await coordinator.render(coordinator.descriptor(source, ordinal));
    }

    expect(render.mock.calls.map(([, source]) => source)).toEqual([
      firstSources[0],
      firstSources[1],
      editedSources[0],
    ]);
  });

  it("invalidates every diagram when the theme changes", async () => {
    const { coordinator, initialize, render } = makeRenderer();
    const sources = ["flowchart TD\nA --> B", "sequenceDiagram\nA->>B: Hi"];
    const wrappers: FakeElement[] = [];

    for (const [ordinal, source] of sources.entries()) {
      const descriptor = coordinator.descriptor(source, ordinal);
      const wrapper = pendingWrapper(descriptor);
      const outcome = await coordinator.render(descriptor);
      applyMermaidBlockOutcome(wrapper, descriptor, outcome);
      wrappers.push(wrapper);
    }
    expect(coordinator.initializeTheme("system")).toBe(false);

    expect(coordinator.initializeTheme("dark")).toBe(true);
    await rerenderVisibleMermaidBlocks(
      new FakeRoot(wrappers) as unknown as HTMLElement,
      coordinator,
    );

    expect(render).toHaveBeenCalledTimes(4);
    expect(wrappers.every((wrapper) => wrapper.innerHTML.includes("<svg"))).toBe(
      true,
    );
    expect(
      wrappers.every(
        (wrapper) => !wrapper.classList.contains("mermaid-pending"),
      ),
    ).toBe(true);
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

  it("shows failures without caching them and retries the next render", async () => {
    const render = vi
      .fn<(id: string, source: string) => Promise<{ svg: string }>>()
      .mockRejectedValueOnce(new Error("bad diagram"))
      .mockResolvedValue({ svg: "<svg>recovered</svg>" });
    const coordinator = new MermaidRenderCoordinator(render, () => {});
    coordinator.initializeTheme("system");
    const descriptor = coordinator.descriptor("not a diagram", 0);
    const wrapper = pendingWrapper(descriptor);

    const failure = await coordinator.render(descriptor);
    expect(applyMermaidBlockOutcome(wrapper, descriptor, failure)).toBe(true);
    expect(wrapper.classList.contains("mermaid-error")).toBe(true);
    expect(wrapper.textContent).toBe("bad diagram");
    expect(coordinator.cacheSize).toBe(0);

    const nextWrapper = pendingWrapper(descriptor);
    expect(shouldUpdatePreviewElement(wrapper, nextWrapper)).toBe(true);
    markMermaidWrapperPending(wrapper, descriptor);
    const success = await coordinator.render(descriptor);
    expect(applyMermaidBlockOutcome(wrapper, descriptor, success)).toBe(true);
    expect(wrapper.classList.contains("mermaid-error")).toBe(false);
    expect(wrapper.innerHTML).toBe("<svg>recovered</svg>");

    await coordinator.render(descriptor);
    expect(render).toHaveBeenCalledTimes(2);
  });

  it("keeps unchanged non-Mermaid highlighted DOM", () => {
    const liveCode = new FakeElement(
      true,
      "let answer = 42;\n",
      ["language-swift", "hljs"],
    );
    liveCode.dataset.highlighted = "yes";
    const highlightedSpan = liveCode.highlightedChild;
    const nextCode = new FakeElement(
      true,
      "let answer = 42;\n",
      ["language-swift"],
    );

    const patchedCode = applyMorphdomPatch(liveCode, nextCode);

    expect(patchedCode).toBe(liveCode);
    expect(patchedCode.highlightedChild).toBe(highlightedSpan);
    expect(patchedCode.dataset.highlighted).toBe("yes");
  });

  it("evicts least-recently-used entries at the configured bound", async () => {
    const render = vi.fn(async (_id: string, source: string) => ({
      svg: `<svg>${source}</svg>`,
    }));
    const coordinator = new MermaidRenderCoordinator(render, () => {}, 2);
    coordinator.initializeTheme("system");

    await coordinator.render(coordinator.descriptor("A", 0));
    await coordinator.render(coordinator.descriptor("B", 0));
    await coordinator.render(coordinator.descriptor("A", 0));
    await coordinator.render(coordinator.descriptor("C", 0));

    expect(coordinator.cacheSize).toBe(2);
    await coordinator.render(coordinator.descriptor("B", 0));
    expect(render.mock.calls.map(([, source]) => source)).toEqual([
      "A",
      "B",
      "C",
      "B",
    ]);
    expect(coordinator.cacheSize).toBe(2);
    expect(MERMAID_RENDER_CACHE_CAPACITY).toBe(64);
  });

  it("does not alias distinct sources that collide under the old djb2 hash", async () => {
    const { coordinator, render } = makeRenderer();
    const collidingSources = [
      "flowchart TD\nwVdFPOv99aKB",
      "flowchart TD\nvFQWu8i_7BNT",
    ];

    expect(legacyDjb2Hash(collidingSources[0])).toBe(
      legacyDjb2Hash(collidingSources[1]),
    );
    await coordinator.render(coordinator.descriptor(collidingSources[0], 0));
    await coordinator.render(coordinator.descriptor(collidingSources[1], 0));

    expect(render.mock.calls.map(([, source]) => source)).toEqual(
      collidingSources,
    );
  });

  it("coalesces overlapping renders for the same exact diagram", async () => {
    let resolveRender: ((result: { svg: string }) => void) | undefined;
    const render = vi.fn(
      () =>
        new Promise<{ svg: string }>((resolve) => {
          resolveRender = resolve;
        }),
    );
    const coordinator = new MermaidRenderCoordinator(render, () => {});
    coordinator.initializeTheme("system");
    const descriptor = coordinator.descriptor("flowchart TD\nA --> B", 0);

    const first = coordinator.render(descriptor);
    const second = coordinator.render(descriptor);
    expect(render).toHaveBeenCalledTimes(1);
    resolveRender?.({ svg: "<svg></svg>" });

    await expect(first).resolves.toMatchObject({ kind: "success" });
    await expect(second).resolves.toMatchObject({ kind: "success" });
    expect(render).toHaveBeenCalledTimes(1);
  });

  it("bounds unresolved in-flight render bookkeeping", async () => {
    const resolvers: Array<(result: { svg: string }) => void> = [];
    const render = vi.fn(
      () =>
        new Promise<{ svg: string }>((resolve) => {
          resolvers.push(resolve);
        }),
    );
    const coordinator = new MermaidRenderCoordinator(render, () => {}, 2);
    coordinator.initializeTheme("system");

    const renders = ["A", "B", "C"].map((source, ordinal) =>
      coordinator.render(coordinator.descriptor(source, ordinal)),
    );

    expect(coordinator.inFlightSize).toBe(2);
    for (const [index, resolve] of resolvers.entries()) {
      resolve({ svg: `<svg>${index}</svg>` });
    }
    await Promise.all(renders);
    expect(coordinator.inFlightSize).toBe(0);
  });
});
