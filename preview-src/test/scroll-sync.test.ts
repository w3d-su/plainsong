import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { BridgeMessage, RenderPayload } from "../src/bridge";

vi.mock("mermaid", () => ({ default: { initialize: vi.fn(), render: vi.fn() } }));

let messages: BridgeMessage[];
let resize: (width: number) => void;
let scrollY: number;
// Layout model: every block is `lineHeight` tall per source line, so a narrower
// viewport (taller wrapped lines) moves every block without any DOM change.
let lineHeight: number;

beforeEach(async () => {
  vi.resetModules();
  messages = [];
  scrollY = 0;
  lineHeight = 20;
  resize = () => {};
  vi.stubGlobal("ResizeObserver", class {
    constructor(private readonly callback: ResizeObserverCallback) {}
    observe() {
      resize = (width) => this.callback(
        [{ contentRect: { width } } as ResizeObserverEntry],
        this as unknown as ResizeObserver,
      );
    }
    disconnect() {}
  });
  vi.spyOn(HTMLElement.prototype, "offsetTop", "get").mockImplementation(function(this: HTMLElement) {
    return (Number.parseInt(this.dataset.line ?? "1", 10) - 1) * lineHeight;
  });
  vi.spyOn(HTMLElement.prototype, "offsetParent", "get").mockImplementation(function(this: HTMLElement) {
    return this.isConnected ? document.body : null;
  });
  vi.spyOn(window, "scrollY", "get").mockImplementation(() => scrollY);
  vi.spyOn(window, "scrollTo").mockImplementation(((options: ScrollToOptions) => {
    scrollY = options.top ?? scrollY;
    window.dispatchEvent(new Event("scroll"));
  }) as typeof window.scrollTo);
  document.body.innerHTML = '<main id="preview-root"></main>';
  window.webkit = { messageHandlers: { bridge: { postMessage: (message) => messages.push(message) } } };
  await import("../src/index");
  resize(600);
});

afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});

async function render(text: string) {
  const payload: RenderPayload = {
    renderID: 1, version: 0, text, fileKind: "md", assetRootID: "root", baseDir: null,
    theme: "light", allowRemoteImages: false,
  };
  window.PlainsongBridge.receive({ name: "render", payload });
  await vi.waitFor(() => expect(messages.some((message) => message.name === "renderComplete")).toBe(true));
}

const paragraphs = Array.from({ length: 200 }, (_, line) => `Paragraph ${line + 1}`).join("\n\n");

describe("preview scroll sync across reflow", () => {
  it("keeps the editor's source line at the top when only the preview width changes", async () => {
    await render(paragraphs);
    window.PlainsongBridge.receive({ name: "scrollToLine", payload: { line: 101, animated: false } });
    expect(scrollY).toBe(100 * 20 - 12);

    // Narrowing doubles every block height; the editor reports no new line.
    lineHeight = 40;
    resize(300);
    expect(scrollY).toBe(100 * 40 - 12);
    // Height-only changes do not reflow and must not move the preview.
    scrollY = 1234;
    resize(300);
    expect(scrollY).toBe(1234);
    await new Promise((resolve) => requestAnimationFrame(resolve));
    expect(messages.filter((message) => message.name === "previewScrolled")).toEqual([]);
  });

  it("re-places a position the user scrolled to inside the preview proportionally", async () => {
    await render(paragraphs);
    // Halfway between the blocks for lines 101 and 103.
    scrollY = 100 * 20 + 20 - 12;
    window.dispatchEvent(new Event("scroll"));
    await vi.waitFor(() => expect(messages.some((message) => message.name === "previewScrolled")).toBe(true));
    const reported = messages.filter((message) => message.name === "previewScrolled");
    expect(reported.at(-1)?.payload).toEqual({ topVisibleLine: 101 });

    lineHeight = 30;
    await new Promise((resolve) => setTimeout(resolve, 120));
    resize(400);
    expect(scrollY).toBe(100 * 30 + 30 - 12);
  });
});
