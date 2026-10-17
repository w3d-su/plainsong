type Anchor = { line: number; top: number };

/** Geometry belongs to a layout, not a scroll event. Both lookup directions are
 * numeric so a warm scroll never traverses the DOM or forces layout. */
export class PreviewScrollIndex {
  private byLine: Anchor[] = [];
  private byTop: Anchor[] = [];
  private dirty = true;
  private frame: number | undefined;
  private disposed = false;
  private readonly mutations: MutationObserver;
  private readonly resize?: ResizeObserver;
  private readonly view: Window;
  private readonly fonts: FontFaceSet | undefined;

  constructor(private readonly root: HTMLElement) {
    this.view = root.ownerDocument.defaultView!;
    this.mutations = new MutationObserver(this.invalidate);
    this.mutations.observe(root, {
      subtree: true, childList: true, characterData: true, attributes: true,
      attributeFilter: ["data-line", "src", "class", "style", "width", "height", "hidden", "open"],
    });
    if (typeof ResizeObserver !== "undefined") {
      this.resize = new ResizeObserver(this.invalidate);
      this.resize.observe(root);
    }
    // Intrinsic image sizes and font metrics can change without a DOM mutation.
    root.addEventListener("load", this.invalidate, true);
    root.addEventListener("error", this.invalidate, true);
    this.view.addEventListener("resize", this.invalidate);
    this.fonts = root.ownerDocument.fonts;
    this.fonts?.addEventListener("loadingdone", this.invalidate);
    this.fonts?.addEventListener("loadingerror", this.invalidate);
    void this.fonts?.ready.then(this.invalidate);
  }

  readonly invalidate = (): void => {
    if (this.disposed) return;
    this.dirty = true;
    if (this.frame !== undefined) return;
    this.frame = this.view.requestAnimationFrame(() => {
      this.frame = undefined;
      this.rebuildIfNeeded();
    });
  };

  topForLine(line: number): number | undefined {
    this.rebuildIfNeeded();
    if (this.byLine.length === 0) return undefined;
    const index = upperBound(this.byLine, line, (anchor) => anchor.line);
    const previous = this.byLine[Math.max(0, index - 1)];
    const next = this.byLine[Math.min(index, this.byLine.length - 1)];
    if (next.line <= previous.line) return previous.top;
    const progress = (line - previous.line) / (next.line - previous.line);
    return previous.top + (next.top - previous.top) * progress;
  }

  lineAtTop(top: number): number | undefined {
    this.rebuildIfNeeded();
    const index = upperBound(this.byTop, top, (anchor) => anchor.top);
    return this.byTop[index - 1]?.line;
  }

  dispose(): void {
    this.disposed = true;
    this.mutations.disconnect();
    this.resize?.disconnect();
    if (this.frame !== undefined) this.view.cancelAnimationFrame(this.frame);
    this.root.removeEventListener("load", this.invalidate, true);
    this.root.removeEventListener("error", this.invalidate, true);
    this.view.removeEventListener("resize", this.invalidate);
    this.fonts?.removeEventListener("loadingdone", this.invalidate);
    this.fonts?.removeEventListener("loadingerror", this.invalidate);
  }

  private rebuildIfNeeded(): void {
    // A bridge message can arrive before the DOM observer's callback.
    if (this.mutations.takeRecords().length > 0) this.dirty = true;
    if (!this.dirty || this.disposed) return;
    if (this.frame !== undefined) this.view.cancelAnimationFrame(this.frame);
    this.frame = undefined;
    this.dirty = false;
    const scrollY = this.view.scrollY;
    this.byLine = Array.from(this.root.querySelectorAll<HTMLElement>("[data-line]"))
      .map((element) => ({
        line: Number.parseInt(element.dataset.line ?? "", 10),
        // offsetTop is relative to offsetParent, not the document in tables/MDX.
        top: element.getBoundingClientRect().top + scrollY,
      }))
      .filter(({ line, top }) => Number.isFinite(line) && Number.isFinite(top))
      .sort((a, b) => a.line - b.line);
    // Nested blocks/table cells need not have monotonic tops in source order.
    this.byTop = [...this.byLine].sort((a, b) => a.top - b.top || a.line - b.line);
  }
}

function upperBound(anchors: Anchor[], value: number, key: (anchor: Anchor) => number): number {
  let lower = 0;
  let upper = anchors.length;
  while (lower < upper) {
    const middle = lower + Math.floor((upper - lower) / 2);
    if (key(anchors[middle]) <= value) lower = middle + 1;
    else upper = middle;
  }
  return lower;
}
