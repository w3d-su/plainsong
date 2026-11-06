import { beforeEach, describe, expect, it, vi } from "vitest";
import perf100 from "../../Fixtures/perf-100kb.md?raw";
import type { BridgeMessage, RenderPayload } from "../src/bridge";

// The bridge renders through the segmented renderer (segmented-render.ts). After edits that
// reuse segments and shift lines, the preview must show what one render of the final text
// shows, and checkbox writeback must report the task's new source line.
let messages: BridgeMessage[];

async function loadPreview(): Promise<void> {
  vi.resetModules();
  messages = [];
  document.body.innerHTML = '<main id="preview-root"></main>';
  window.webkit = { messageHandlers: { bridge: { postMessage: (message) => messages.push(message) } } };
  await import("../src/index");
}

async function render(renderID: number, text: string, fileKind: RenderPayload["fileKind"] = "md"): Promise<void> {
  const payload: RenderPayload = {
    renderID, version: renderID, text, fileKind, assetRootID: "root", baseDir: null,
    theme: "light", allowRemoteImages: false,
  };
  window.PlainsongBridge.receive({ name: "render", payload });
  await vi.waitFor(() => expect(messages.some((message) =>
    message.name === "renderComplete" && message.payload.renderID === renderID,
  )).toBe(true));
}

function previewHTML(): string {
  return document.getElementById("preview-root")!.innerHTML;
}

beforeEach(loadPreview);

describe("segmented preview rendering through the bridge", () => {
  it("shows the same preview as one render of the final text", { timeout: 60_000 }, async () => {
    const middle = perf100.indexOf("\n## Section 00008");
    // Shift every later line, and repeat a heading so later IDs gain suffixes.
    const inserted = `${perf100.slice(0, middle)}\n## Section 00001\n\nInserted $x$ and\ntwo lines.\n${perf100.slice(middle)}`;
    const end = inserted.lastIndexOf("\n## Section");
    const edits = [perf100, inserted, `${inserted.slice(0, end)}\n\nTyped near the end.\n${inserted.slice(end)}`];
    for (const [index, text] of edits.entries()) await render(index + 1, text);
    const incremental = previewHTML();

    await loadPreview();
    await render(1, edits.at(-1)!);
    expect(incremental).toBe(previewHTML());
  });

  it("renders each file kind with its own pipeline after a switch", { timeout: 60_000 }, async () => {
    const mdx = `import Button from "./Button"\n\n${perf100.replace(/^---[\s\S]*?\n---\n/u, "")}\n\n<Button>Go</Button>\n`;
    await render(1, perf100);
    await render(2, mdx, "mdx");
    const edited = `${perf100}\n\nTyped at the end.\n`;
    await render(3, edited);
    const switched = previewHTML();

    await loadPreview();
    await render(1, edited);
    expect(switched).toBe(previewHTML());
  });

  it("reports a task's current source line after an edit above it", { timeout: 60_000 }, async () => {
    await render(1, perf100);
    const edited = `Inserted paragraph.\n\nSecond line.\n\n${perf100}`;
    await render(2, edited);

    document.querySelectorAll<HTMLInputElement>('input[data-task-checkbox="true"]')[10].click();
    const toggle = messages.filter((message) => message.name === "checkboxToggled").at(-1);
    const taskLines = edited.split("\n").flatMap((source, index) => (/^- \[[ x]\] /u.test(source) ? [index + 1] : []));
    expect(toggle?.name === "checkboxToggled" ? toggle.payload.line : undefined).toBe(taskLines[10]);
  });
});
