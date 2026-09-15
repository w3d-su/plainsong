import { beforeEach, describe, expect, it, vi } from "vitest";
import type { BridgeMessage, RenderPayload } from "../src/bridge";

const diagram = vi.hoisted(() => ({
  render: vi.fn(async () => ({ svg: "<svg></svg>" })),
  initialize: vi.fn(),
}));
vi.mock("mermaid", () => ({ default: diagram }));

let messages: BridgeMessage[];

beforeEach(async () => {
  vi.resetModules();
  diagram.render.mockReset();
  diagram.render.mockResolvedValue({ svg: "<svg></svg>" });
  messages = [];
  document.body.innerHTML = '<main id="preview-root"></main>';
  window.webkit = { messageHandlers: { bridge: {
    postMessage: (message: BridgeMessage) => messages.push(message),
  } } };
  await import("../src/index");
});

function render(renderID: number, text: string, fileKind: "md" | "mdx" = "md") {
  const payload: RenderPayload = {
    renderID, version: 0, text, fileKind, baseDir: null, assetRootID: "test-root",
    theme: "light", allowRemoteImages: false,
  };
  window.PlainsongBridge.receive({ name: "render", payload });
}

function clickCheckbox() {
  document.querySelector<HTMLInputElement>("input[data-task-checkbox]")!.click();
  return messages.filter((message) => message.name === "checkboxToggled").at(-1);
}

async function waitForRender(renderID: number) {
  await vi.waitFor(() => expect(messages.some((message) =>
    message.name === "renderComplete" && message.payload.renderID === renderID,
  )).toBe(true));
}

describe("checkbox DOM provenance", () => {
  it("keeps the old render ID when a same-version MDX document retains the old DOM", async () => {
    render(10, "- [ ] original");
    await waitForRender(10);
    render(11, "- [ ] replacement\n<Component", "mdx");
    await waitForRender(11);
    expect(document.querySelector(".mdx-error-banner")).not.toBeNull();
    expect(clickCheckbox()).toEqual({
      name: "checkboxToggled",
      payload: { renderID: 10, version: 0, line: 1, checked: true },
    });
    render(12, "- [ ] current");
    await waitForRender(12);
    expect(clickCheckbox()?.payload).toMatchObject({ renderID: 12, version: 0 });
  });

  it("moves checkbox provenance with the DOM while Mermaid is still pending", async () => {
    render(20, "- [ ] original");
    await waitForRender(20);
    let finish!: (result: { svg: string }) => void;
    diagram.render.mockImplementationOnce(() => new Promise((resolve) => { finish = resolve; }));
    render(21, "- [ ] current\n\n```mermaid\nflowchart TD\nA --> B\n```");
    await vi.waitFor(() => expect(document.querySelector(".mermaid-pending")).not.toBeNull());
    expect(messages.some((message) => message.name === "renderComplete" && message.payload.renderID === 21)).toBe(false);
    expect(clickCheckbox()?.payload).toMatchObject({ renderID: 21, version: 0, line: 1 });
    finish({ svg: "<svg></svg>" });
    await waitForRender(21);
  });
});
