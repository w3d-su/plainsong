import { beforeEach, describe, expect, it, type MockInstance, vi } from "vitest";
import type { BridgeMessage, RenderPayload } from "../src/bridge";

vi.mock("mermaid", () => ({ default: { initialize: vi.fn(), render: vi.fn() } }));
let messages: BridgeMessage[];
let highlightElement: MockInstance<(element: HTMLElement) => void>;
let maxLength: number;
beforeEach(async () => {
  vi.resetModules();
  messages = [];
  document.body.innerHTML = '<main id="preview-root"></main>';
  window.webkit = { messageHandlers: { bridge: { postMessage: (message) => messages.push(message) } } };
  const { default: hljs } = await import("highlight.js/lib/core");
  vi.restoreAllMocks();
  highlightElement = vi.spyOn(hljs, "highlightElement");
  ({ AUTO_DETECT_MAX_LENGTH: maxLength } = await import("../src/code-highlight"));
  await import("../src/index");
});

async function render(renderID: number, text: string) {
  const payload: RenderPayload = {
    renderID, version: 0, text, fileKind: "md", assetRootID: "root", baseDir: null,
    theme: "light", allowRemoteImages: false,
  };
  window.PlainsongBridge.receive({ name: "render", payload });
  await vi.waitFor(() => expect(messages.some((message) =>
    message.name === "renderComplete" && message.payload.renderID === renderID,
  )).toBe(true));
}

// remark ends a fence's code text with "\n", so the body is one char shorter.
const fence = (body: string, language = "") => "```" + language + "\n" + body + "\n```";
const codes = () => [...document.querySelectorAll<HTMLElement>("pre code")];

describe("code fence highlighting", () => {
  it("auto-detects a small bare fence", async () => {
    await render(1, fence("function greet(name) {\n  return `Hello, ${name}`;\n}"));
    const [code] = codes();
    expect(highlightElement).toHaveBeenCalledWith(code);
    expect(code.className).toMatch(/\blanguage-\w+/);
    expect(code.querySelector("[class^=hljs-]")).not.toBeNull();
  });

  it("auto-detects at the threshold and renders plain text one char past it", async () => {
    await render(1, fence("W".repeat(maxLength - 1)) + "\n\n" + fence("W".repeat(maxLength)));
    const [atLimit, pastLimit] = codes();
    expect(atLimit.textContent).toHaveLength(maxLength);
    expect(pastLimit.textContent).toHaveLength(maxLength + 1);
    expect(highlightElement.mock.calls.map(([element]) => element)).toEqual([atLimit]);
    expect(pastLimit.className).toBe("hljs");
    expect(pastLimit.dataset.highlighted).toBe("yes");
  });

  it("skips auto-detection for a large bare fence and keeps that DOM across renders", { timeout: 10_000 }, async () => {
    // 240,000 chars took ~113 s to auto-detect, past the 15 s export render timeout.
    const body = "W".repeat(240_000);
    const start = performance.now();
    await render(1, fence(body));
    expect(performance.now() - start).toBeLessThan(5_000);
    const [code] = codes();
    expect(highlightElement).not.toHaveBeenCalled();
    expect(code.textContent).toBe(body + "\n");
    expect(code.children).toHaveLength(0);
    expect(code.className).toBe("hljs");

    await render(2, fence(body) + "\n\nEdit");
    expect(codes()[0]).toBe(code);
    expect(highlightElement).not.toHaveBeenCalled();
  });

  it("still highlights a large fence with an explicit language", async () => {
    await render(1, fence("let answer = 42;\n".repeat(400), "swift"));
    const [code] = codes();
    expect(code.textContent!.length).toBeGreaterThan(maxLength);
    expect(highlightElement).toHaveBeenCalledWith(code);
    expect(code.querySelector(".hljs-keyword")).not.toBeNull();
  });
});
