type Anchor = { line: number; element: HTMLElement };
type PlacedAnchor = Anchor & { top: number };

/** Maps source lines to document tops and back for scroll sync.
 *
 * The anchor list depends only on the DOM and is rebuilt after mutations. Geometry is
 * read live for the one or two anchors a lookup uses, so a window resize, image load or
 * font swap is reflected without waiting for resize/load events (WebKit can expose a new
 * layout before delivering them) and without re-measuring every anchor per resize frame.
 * The top-ordered list for preview → editor lookups is measured lazily and re-measured
 * only when an anchor bounding the answer has moved. */
export class PreviewScrollIndex {
  private anchors: Anchor[] | undefined;
  private byTop: PlacedAnchor[] | undefined;
  private readonly mutations: MutationObserver;

  constructor(private readonly root: HTMLElement) {
    this.mutations = new MutationObserver(this.invalidate);
    this.mutations.observe(root, {
      subtree: true, childList: true, attributes: true, attributeFilter: ["data-line"],
    });
  }

  readonly invalidate = (): void => {
    this.anchors = undefined;
    this.byTop = undefined;
  };

  /** Document top for a (possibly fractional) source line, interpolated between the
   * nearest rendered anchors. */
  topForLine(line: number): number | undefined {
    const anchors = this.currentAnchors();
    const index = upperBound(anchors, line, (anchor) => anchor.line);
    const previous = renderedAnchor(anchors, index - 1, -1) ?? renderedAnchor(anchors, index, 1);
    if (previous === undefined) return undefined;
    const next = renderedAnchor(anchors, index, 1);
    if (next === undefined || next.line <= previous.line) return previous.top;
    const progress = Math.min(1, Math.max(0, (line - previous.line) / (next.line - previous.line)));
    return previous.top + (next.top - previous.top) * progress;
  }

  /** The source line of the last anchor starting at or above `top`. */
  lineAtTop(top: number): number | undefined {
    const placed = this.currentByTop(top);
    return placed[upperBound(placed, top, (anchor) => anchor.top) - 1]?.line;
  }

  /** Fractional source position at `top`, the inverse of `topForLine` between two
   * anchors in source order. Used to keep the same content in view across reflow. */
  positionAtTop(top: number): number | undefined {
    const placed = this.currentByTop(top);
    const index = upperBound(placed, top, (anchor) => anchor.top);
    const previous = placed[index - 1];
    if (previous === undefined) return placed[0]?.line;
    const next = placed[index];
    if (next === undefined || next.line <= previous.line || next.top <= previous.top) return previous.line;
    return previous.line + ((top - previous.top) / (next.top - previous.top)) * (next.line - previous.line);
  }

  dispose(): void {
    this.mutations.disconnect();
  }

  private currentAnchors(): Anchor[] {
    // A bridge message can arrive before the observer's callback.
    if (this.mutations.takeRecords().length > 0) this.invalidate();
    this.anchors ??= Array.from(this.root.querySelectorAll<HTMLElement>("[data-line]"))
      .map((element) => ({ line: Number.parseInt(element.dataset.line ?? "", 10), element }))
      .filter(({ line }) => Number.isFinite(line))
      .sort((a, b) => a.line - b.line);
    return this.anchors;
  }

  private currentByTop(top: number): PlacedAnchor[] {
    const anchors = this.currentAnchors();
    let placed = this.byTop;
    if (placed !== undefined && !boundsAreCurrent(placed, upperBound(placed, top, (anchor) => anchor.top))) {
      placed = undefined;
    }
    if (placed === undefined) {
      placed = anchors
        .map((anchor) => ({ ...anchor, top: documentTop(anchor.element) }))
        .filter((anchor): anchor is PlacedAnchor => anchor.top !== undefined)
        // Nested blocks and table cells need not have monotonic tops in source order.
        .sort((a, b) => a.top - b.top || a.line - b.line);
      this.byTop = placed;
    }
    return placed;
  }
}

/** The nearest anchor from `index` in `step` direction that is laid out, with its top. */
function renderedAnchor(anchors: Anchor[], index: number, step: 1 | -1): PlacedAnchor | undefined {
  for (let current = index; current >= 0 && current < anchors.length; current += step) {
    const top = documentTop(anchors[current].element);
    if (top !== undefined) return { ...anchors[current], top };
  }
  return undefined;
}

/** The anchors on either side of a lookup decide its answer; if neither moved since
 * measurement, the cached answer is still the live one. */
function boundsAreCurrent(placed: PlacedAnchor[], index: number): boolean {
  return [placed[index - 1], placed[index]].every((anchor) =>
    anchor === undefined || Math.abs((documentTop(anchor.element) ?? Number.NaN) - anchor.top) < 1);
}

/** Layout-space top, independent of the scroll position. `offsetTop` is relative to the
 * offset parent, so walk positioned ancestors and table cells (tables/MDX). Unrendered
 * elements (`display: none`, closed `<details>`, detached) have no offset parent. */
function documentTop(element: HTMLElement): number | undefined {
  const body = element.ownerDocument.body;
  let parent = element.offsetParent as HTMLElement | null;
  if (parent === null) return undefined;
  let top = element.offsetTop;
  while (parent !== null && parent !== body) {
    top += parent.offsetTop + parent.clientTop;
    parent = parent.offsetParent as HTMLElement | null;
  }
  return top;
}

function upperBound<T>(items: T[], value: number, key: (item: T) => number): number {
  let lower = 0;
  let upper = items.length;
  while (lower < upper) {
    const middle = lower + Math.floor((upper - lower) / 2);
    if (key(items[middle]) <= value) lower = middle + 1;
    else upper = middle;
  }
  return lower;
}
