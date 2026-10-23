import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { BridgeMessage, RenderPayload } from "../src/bridge";
import {
  LazyMermaid,
  loadMermaidScript,
  MERMAID_SCRIPT_SOURCE,
  type MermaidAPI,
} from "../src/mermaid-loader";
import type { MermaidInitialization, MermaidRenderResult } from "../src/mermaid-renderer";

function fakeMermaid() {
  return {
    initialize: vi.fn<(configuration: MermaidInitialization) => void>(),
    render: vi.fn<(id: string, source: string) => Promise<MermaidRenderResult>>(
      async (id) => ({ svg: `<svg id="${id}"></svg>` }),
    ),
  };
}

const light = { startOnLoad: false, securityLevel: "strict", theme: "default" } as const;
const dark = { startOnLoad: false, securityLevel: "strict", theme: "dark" } as const;

function mermaidScripts(): HTMLScriptElement[] {
  return Array.from(
    document.head.querySelectorAll<HTMLScriptElement>(`script[src="${MERMAID_SCRIPT_SOURCE}"]`),
  );
}

afterEach(() => {
  delete window.PlainsongMermaid;
  document.head.innerHTML = "";
});

describe("LazyMermaid", () => {
  it("does not load until the first render and applies the latest theme on load", async () => {
    const api = fakeMermaid();
    const load = vi.fn(async () => api);
    const mermaid = new LazyMermaid(load);

    mermaid.initialize(light);
    mermaid.initialize(dark);
    expect(load).not.toHaveBeenCalled();
    expect(mermaid.isLoaded).toBe(false);

    await expect(mermaid.render("d1", "flowchart TD")).resolves.toEqual({ svg: '<svg id="d1"></svg>' });
    expect(load).toHaveBeenCalledTimes(1);
    expect(api.initialize.mock.calls).toEqual([[dark]]);
    expect(api.initialize.mock.invocationCallOrder[0])
      .toBeLessThan(api.render.mock.invocationCallOrder[0]);

    mermaid.initialize(light);
    expect(api.initialize.mock.calls.at(-1)).toEqual([light]);
  });

  it("shares one load between concurrent renders", async () => {
    const api = fakeMermaid();
    let finish!: (api: MermaidAPI) => void;
    const load = vi.fn(() => new Promise<MermaidAPI>((resolve) => { finish = resolve; }));
    const mermaid = new LazyMermaid(load);
    mermaid.initialize(light);

    const first = mermaid.render("a", "graph A");
    const second = mermaid.render("b", "graph B");
    finish(api);

    await expect(Promise.all([first, second])).resolves.toHaveLength(2);
    expect(load).toHaveBeenCalledTimes(1);
    expect(api.initialize).toHaveBeenCalledTimes(1);
  });

  it("rejects pending renders when loading fails and retries on the next render", async () => {
    const api = fakeMermaid();
    const load = vi.fn<() => Promise<MermaidAPI>>()
      .mockRejectedValueOnce(new Error("Mermaid failed to load"))
      .mockResolvedValueOnce(api);
    const mermaid = new LazyMermaid(load);
    mermaid.initialize(light);

    await expect(mermaid.render("a", "graph A")).rejects.toThrow("Mermaid failed to load");
    await expect(mermaid.render("b", "graph B")).resolves.toEqual({ svg: '<svg id="b"></svg>' });
    expect(load).toHaveBeenCalledTimes(2);
  });
});

describe("loadMermaidScript", () => {
  it("uses an already loaded Mermaid without adding a script", async () => {
    const api = fakeMermaid();
    window.PlainsongMermaid = { default: api };

    await expect(loadMermaidScript(document)).resolves.toBe(api);
    expect(mermaidScripts()).toHaveLength(0);
  });

  it("adds one classic script and resolves with its global once it loads", async () => {
    const loaded = loadMermaidScript(document);
    const [script] = mermaidScripts();
    expect(script).toBeDefined();
    expect(script.type).toBe("");

    const api = fakeMermaid();
    window.PlainsongMermaid = { default: api };
    script.dispatchEvent(new Event("load"));

    await expect(loaded).resolves.toBe(api);
  });

  it("rejects and removes the script when it fails to load or define Mermaid", async () => {
    const failed = loadMermaidScript(document);
    mermaidScripts()[0].dispatchEvent(new Event("error"));
    await expect(failed).rejects.toThrow("Mermaid failed to load");

    const empty = loadMermaidScript(document);
    mermaidScripts()[0].dispatchEvent(new Event("load"));
    await expect(empty).rejects.toThrow("Mermaid failed to load");
    expect(mermaidScripts()).toHaveLength(0);
  });
});

describe("preview entry", () => {
  let messages: BridgeMessage[];

  beforeEach(async () => {
    vi.resetModules();
    messages = [];
    document.body.innerHTML = '<main id="preview-root"></main>';
    window.webkit = { messageHandlers: { bridge: {
      postMessage: (message: BridgeMessage) => messages.push(message),
    } } };
    await import("../src/index");
  });

  function render(renderID: number, text: string) {
    const payload: RenderPayload = {
      renderID, version: renderID, text, fileKind: "md", baseDir: null,
      assetRootID: "test-root", theme: "dark", allowRemoteImages: false,
    };
    window.PlainsongBridge.receive({ name: "render", payload });
  }

  function completed(renderID: number): boolean {
    return messages.some((message) =>
      message.name === "renderComplete" && message.payload.renderID === renderID);
  }

  it("never loads Mermaid for a document without diagrams", async () => {
    render(1, "# Title\n\n```ts\nconst a = 1\n```\n");
    await vi.waitFor(() => expect(completed(1)).toBe(true));
    expect(mermaidScripts()).toHaveLength(0);
  });

  it("loads Mermaid once for the first diagrams and renders them with the current theme", async () => {
    render(1, "```mermaid\ngraph A\n```\n\n```mermaid\ngraph B\n```\n");
    await vi.waitFor(() => expect(mermaidScripts()).toHaveLength(1));
    expect(completed(1)).toBe(false);

    const api = fakeMermaid();
    window.PlainsongMermaid = { default: api };
    mermaidScripts()[0].dispatchEvent(new Event("load"));

    await vi.waitFor(() => expect(completed(1)).toBe(true));
    expect(api.initialize.mock.calls).toEqual([[dark]]);
    expect(api.render).toHaveBeenCalledTimes(2);
    expect(document.querySelectorAll(".mermaid-rendered svg")).toHaveLength(2);
    expect(mermaidScripts()).toHaveLength(1);
  });
});
