import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { PreviewScrollIndex } from "../src/scroll-index";

let root: HTMLElement;
let index: PreviewScrollIndex;
let reads: number;
// jsdom has no layout: model offsetTop relative to an offset parent (body by default).
const tops = new WeakMap<Element, number>();
const offsetParents = new WeakMap<Element, Element | null>();
const clientTops = new WeakMap<Element, number>();

beforeEach(() => {
  document.body.innerHTML = '<main id="preview-root"></main>';
  root = document.getElementById("preview-root")!;
  reads = 0;
  vi.spyOn(HTMLElement.prototype, "offsetTop", "get").mockImplementation(function(this: HTMLElement) {
    reads++;
    return tops.get(this) ?? 0;
  });
  vi.spyOn(HTMLElement.prototype, "offsetParent", "get").mockImplementation(function(this: HTMLElement) {
    if (offsetParents.has(this)) return offsetParents.get(this)!;
    return this.isConnected ? document.body : null;
  });
  vi.spyOn(Element.prototype, "clientTop", "get").mockImplementation(function(this: Element) {
    return clientTops.get(this) ?? 0;
  });
  index = new PreviewScrollIndex(root);
});

afterEach(() => {
  index.dispose();
  vi.restoreAllMocks();
});

function anchor(line: number, top: number, parent: Element = root): HTMLElement {
  const element = document.createElement("p");
  element.dataset.line = String(line);
  tops.set(element, top);
  parent.append(element);
  return element;
}

describe("preview scroll geometry index", () => {
  it("interpolates source lines, clamps edges and maps layout coordinates both ways", () => {
    anchor(5, 100);
    anchor(15, 300);
    expect(index.topForLine(0)).toBe(100);
    expect(index.topForLine(10)).toBe(200);
    expect(index.topForLine(12.5)).toBe(250);
    expect(index.topForLine(99)).toBe(300);
    expect(index.lineAtTop(99)).toBeUndefined();
    expect(index.lineAtTop(100)).toBe(5);
    expect(index.lineAtTop(299)).toBe(5);
    expect(index.lineAtTop(300)).toBe(15);
    expect(index.positionAtTop(250)).toBe(12.5);
    expect(index.positionAtTop(50)).toBe(5);
    expect(index.positionAtTop(400)).toBe(15);
    // Layout coordinates do not depend on the scroll position.
    vi.spyOn(window, "scrollY", "get").mockReturnValue(250);
    expect(index.topForLine(10)).toBe(200);
    expect(index.lineAtTop(300)).toBe(15);
  });

  it("handles empty roots, duplicate lines and nested anchors inside offset parents", () => {
    expect(index.topForLine(1)).toBeUndefined();
    expect(index.lineAtTop(0)).toBeUndefined();
    expect(index.positionAtTop(0)).toBeUndefined();
    const parent = anchor(1, 100);
    anchor(1, 120, parent);
    anchor(3, 110, parent);
    anchor(5, 200);
    expect(index.topForLine(1)).toBe(120);
    expect(index.topForLine(4)).toBe(155);
    expect(index.lineAtTop(115)).toBe(3);
    expect(index.lineAtTop(125)).toBe(1);

    // A table cell or positioned MDX wrapper: offsetTop is relative to its padding edge.
    const wrapper = document.createElement("div");
    root.append(wrapper);
    tops.set(wrapper, 1000);
    clientTops.set(wrapper, 2);
    const nested = anchor(9, 30, wrapper);
    offsetParents.set(nested, wrapper);
    expect(index.topForLine(9)).toBe(1032);
    expect(index.lineAtTop(1032)).toBe(9);
  });

  it("skips anchors that are not laid out in both directions", () => {
    anchor(1, 100);
    const hidden = anchor(5, 0);
    offsetParents.set(hidden, null);
    anchor(9, 300);
    expect(index.topForLine(5)).toBe(200);
    expect(index.topForLine(7)).toBe(250);
    expect(index.lineAtTop(10)).toBeUndefined();
    expect(index.lineAtTop(150)).toBe(1);
    root.firstElementChild!.remove();
    expect(index.topForLine(1)).toBe(300);
  });

  it("queries the DOM once and reads O(1) geometry per warm large-document lookup", () => {
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
    expect(reads).toBeLessThanOrEqual(2);
    expect(index.lineAtTop(500_000)).toBe(25_000);
    const measured = reads;
    for (let step = 0; step < 200; step++) {
      expect(index.lineAtTop(500_000 + step * 20)).toBe(25_000 + step);
      expect(index.topForLine(25_000 - step)).toBe((25_000 - step) * 20);
    }
    expect(query).toHaveBeenCalledTimes(1);
    expect(reads - measured).toBeLessThanOrEqual(200 * 4);
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

  it("follows layout changes that arrive without any DOM, resize or load event", () => {
    const first = anchor(1, 10);
    const second = anchor(2, 50);
    const third = anchor(3, 90);
    expect(index.topForLine(2)).toBe(50);
    expect(index.lineAtTop(60)).toBe(2);
    // A narrower viewport reflows every block; nothing has been delivered yet.
    tops.set(first, 10);
    tops.set(second, 100);
    tops.set(third, 190);
    expect(index.topForLine(2)).toBe(100);
    expect(index.topForLine(2.5)).toBe(145);
    expect(index.lineAtTop(60)).toBe(1);
    expect(index.lineAtTop(150)).toBe(2);
    expect(index.positionAtTop(145)).toBe(2.5);
  });

  it("re-measures the top-ordered list only when an anchor bounding the answer moved", () => {
    const elements = Array.from({ length: 100 }, (_, offset) => anchor(offset + 1, offset * 10));
    expect(index.lineAtTop(15)).toBe(2);
    let before = reads;
    expect(index.lineAtTop(25)).toBe(3);
    expect(reads - before).toBe(2);
    // Content far below the lookup grows (a Mermaid diagram or image settles).
    for (const element of elements.slice(80)) tops.set(element, tops.get(element)! + 500);
    before = reads;
    expect(index.lineAtTop(25)).toBe(3);
    expect(reads - before).toBe(2);
    expect(index.lineAtTop(1300)).toBe(81);
    expect(reads - before).toBeGreaterThan(100);
    before = reads;
    expect(index.lineAtTop(1310)).toBe(82);
    expect(reads - before).toBe(2);
  });
});
