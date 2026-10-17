import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { PreviewScrollIndex } from "../src/scroll-index";

let root: HTMLElement;
let index: PreviewScrollIndex;
let reads: number;
let resize: ResizeObserverCallback;
const tops = new WeakMap<Element, number>();

beforeEach(() => {
  document.body.innerHTML = '<main id="preview-root"></main>';
  root = document.getElementById("preview-root")!;
  reads = 0;
  vi.stubGlobal("ResizeObserver", class {
    constructor(callback: ResizeObserverCallback) { resize = callback; }
    observe() {}
    disconnect() {}
  });
  vi.spyOn(Element.prototype, "getBoundingClientRect").mockImplementation(function(this: Element) {
    reads++;
    return { top: (tops.get(this) ?? 0) - window.scrollY } as DOMRect;
  });
  index = new PreviewScrollIndex(root);
});

afterEach(() => {
  index.dispose();
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});

function anchor(line: number, top: number, parent = root): HTMLElement {
  const element = document.createElement("p");
  element.dataset.line = String(line);
  tops.set(element, top);
  parent.append(element);
  return element;
}

describe("preview scroll geometry index", () => {
  it("interpolates source lines, clamps edges and maps document coordinates both ways", () => {
    anchor(5, 100);
    anchor(15, 300);
    expect(index.topForLine(0)).toBe(100);
    expect(index.topForLine(10)).toBe(200);
    expect(index.topForLine(99)).toBe(300);
    expect(index.lineAtTop(99)).toBeUndefined();
    expect(index.lineAtTop(100)).toBe(5);
    expect(index.lineAtTop(299)).toBe(5);
    expect(index.lineAtTop(300)).toBe(15);
    vi.spyOn(window, "scrollY", "get").mockReturnValue(250);
    index.invalidate();
    expect(index.topForLine(10)).toBe(200);
    expect(index.lineAtTop(300)).toBe(15);
  });

  it("handles empty roots, duplicate lines and nested anchors with different offset parents", () => {
    expect(index.topForLine(1)).toBeUndefined();
    const parent = anchor(1, 100);
    anchor(1, 120, parent);
    anchor(3, 110, parent);
    anchor(5, 200);
    expect(index.topForLine(1)).toBe(120);
    expect(index.topForLine(4)).toBe(155);
    expect(index.lineAtTop(115)).toBe(3);
    expect(index.lineAtTop(125)).toBe(1);
  });

  it("performs no DOM queries or geometry reads for repeated warm large-document scrolls", () => {
    const fragment = document.createDocumentFragment();
    for (let line = 1; line <= 32_000; line++) {
      const element = document.createElement("p");
      element.dataset.line = String(line);
      tops.set(element, line * 20);
      fragment.append(element);
    }
    root.append(fragment);
    const query = vi.spyOn(root, "querySelectorAll");
    expect(index.topForLine(25_000)).toBe(500_000);
    expect(reads).toBe(32_000);
    for (let step = 0; step < 200; step++) {
      expect(index.lineAtTop(500_000 + step * 20)).toBe(25_000 + step);
      expect(index.topForLine(25_000 - step)).toBe((25_000 - step) * 20);
    }
    expect(query).toHaveBeenCalledTimes(1);
    expect(reads).toBe(32_000);
  });

  it("invalidates synchronously after document replacement and data-line changes", () => {
    anchor(1, 10);
    expect(index.topForLine(1)).toBe(10);
    root.replaceChildren();
    const next = anchor(20, 400);
    expect(index.topForLine(20)).toBe(400);
    next.dataset.line = "30";
    expect(index.lineAtTop(400)).toBe(30);
    root.replaceChildren();
    expect(index.topForLine(1)).toBeUndefined();
  });

  it("coalesces invalidation and refreshes for image loads, errors and viewport/root resizing", () => {
    const element = anchor(1, 10);
    const image = document.createElement("img");
    root.prepend(image);
    expect(index.topForLine(1)).toBe(10);
    for (const event of ["load", "error"]) {
      tops.set(element, 80);
      image.dispatchEvent(new Event(event));
      expect(index.topForLine(1)).toBe(80);
    }
    tops.set(element, 120);
    window.dispatchEvent(new Event("resize"));
    expect(index.topForLine(1)).toBe(120);
    tops.set(element, 160);
    resize([], {} as ResizeObserver);
    index.invalidate();
    index.invalidate();
    const before = reads;
    expect(index.topForLine(1)).toBe(160);
    expect(index.topForLine(1)).toBe(160);
    expect(reads - before).toBe(1);
  });

  it("refreshes after asynchronous Mermaid/error-banner mutations even when root height is unchanged", async () => {
    const element = anchor(10, 100);
    expect(index.topForLine(10)).toBe(100);
    tops.set(element, 300);
    root.prepend(document.createElement("aside"));
    await Promise.resolve();
    expect(index.topForLine(10)).toBe(300);
    element.style.height = "200px";
    tops.set(element, 400);
    expect(index.topForLine(10)).toBe(400);
  });

  it("invalidates when fonts settle without a DOM mutation", async () => {
    index.dispose();
    const descriptor = Object.getOwnPropertyDescriptor(document, "fonts");
    const fonts = Object.assign(new EventTarget(), { ready: Promise.resolve() });
    Object.defineProperty(document, "fonts", { configurable: true, value: fonts });
    try {
      index = new PreviewScrollIndex(root);
      const element = anchor(1, 10);
      expect(index.topForLine(1)).toBe(10);
      tops.set(element, 20);
      await Promise.resolve();
      expect(index.topForLine(1)).toBe(20);
      tops.set(element, 30);
      fonts.dispatchEvent(new Event("loadingdone"));
      expect(index.topForLine(1)).toBe(30);
    } finally {
      index.dispose();
      if (descriptor) Object.defineProperty(document, "fonts", descriptor);
      else Reflect.deleteProperty(document, "fonts");
    }
  });
});
