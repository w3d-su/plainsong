import { describe, expect, it, vi } from "vitest";
import {
  MERMAID_RENDER_CACHE_CAPACITY,
  MermaidRenderCoordinator,
} from "../src/mermaid-renderer";

function legacyDjb2Hash(value: string): string {
  let hash = 5381;
  for (let index = 0; index < value.length; index += 1) {
    hash = (hash * 33) ^ value.charCodeAt(index);
  }
  return (hash >>> 0).toString(36);
}

function makeRenderer() {
  const render = vi.fn(async (_id: string, source: string) => ({
    svg: `<svg data-source="${encodeURIComponent(source)}"></svg>`,
  }));
  const coordinator = new MermaidRenderCoordinator(render, () => {});
  coordinator.initializeTheme("system");
  return { coordinator, render };
}

describe("Mermaid render coordination", () => {
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
