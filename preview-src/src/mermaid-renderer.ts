export const MERMAID_RENDER_CACHE_CAPACITY = 64;

export interface MermaidInitialization {
  startOnLoad: false;
  securityLevel: "strict";
  theme: "dark" | "default";
}

export interface MermaidRenderResult {
  svg: string;
}

export interface MermaidBlockDescriptor {
  source: string;
  ordinal: number;
  themeGeneration: number;
}

export type MermaidBlockOutcome =
  | {
      kind: "success";
      svg: string;
      fromCache: boolean;
    }
  | {
      kind: "error";
      message: string;
    }
  | {
      kind: "stale";
    };

interface MermaidMemoEntry {
  source: string;
  ordinal: number;
  svg: string;
}

type MermaidRenderFunction = (
  id: string,
  source: string,
) => Promise<MermaidRenderResult>;
type MermaidInitializeFunction = (configuration: MermaidInitialization) => void;

export class MermaidRenderMemo {
  private readonly entries = new Map<string, MermaidMemoEntry>();

  constructor(readonly capacity: number = MERMAID_RENDER_CACHE_CAPACITY) {
    if (!Number.isInteger(capacity) || capacity < 1) {
      throw new Error("Mermaid memo capacity must be a positive integer");
    }
  }

  get size(): number {
    return this.entries.size;
  }

  get(source: string, ordinal: number): string | undefined {
    const key = mermaidMemoLookupKey(source, ordinal);
    const entry = this.entries.get(key);
    if (!entry || entry.source !== source || entry.ordinal !== ordinal) {
      return undefined;
    }

    this.entries.delete(key);
    this.entries.set(key, entry);
    return entry.svg;
  }

  set(source: string, ordinal: number, svg: string): void {
    const key = mermaidMemoLookupKey(source, ordinal);
    this.entries.delete(key);
    this.entries.set(key, { source, ordinal, svg });

    while (this.entries.size > this.capacity) {
      const oldestKey = this.entries.keys().next().value;
      if (oldestKey === undefined) break;
      this.entries.delete(oldestKey);
    }
  }

  clear(): void {
    this.entries.clear();
  }
}

export class MermaidRenderCoordinator {
  private readonly memo: MermaidRenderMemo;
  private readonly inFlight = new Map<string, Promise<string>>();
  private readonly inFlightCapacity: number;
  private theme: string | undefined;
  private generation = 0;
  private nextRenderSequence = 0;

  constructor(
    private readonly renderFunction: MermaidRenderFunction,
    private readonly initializeFunction: MermaidInitializeFunction,
    cacheCapacity: number = MERMAID_RENDER_CACHE_CAPACITY,
  ) {
    this.memo = new MermaidRenderMemo(cacheCapacity);
    this.inFlightCapacity = cacheCapacity;
  }

  get cacheSize(): number {
    return this.memo.size;
  }

  get inFlightSize(): number {
    return this.inFlight.size;
  }

  initializeTheme(theme: string): boolean {
    if (theme === this.theme) return false;

    this.initializeFunction({
      startOnLoad: false,
      securityLevel: "strict",
      theme: theme === "dark" ? "dark" : "default",
    });
    this.theme = theme;
    this.generation += 1;
    this.memo.clear();
    this.inFlight.clear();
    return true;
  }

  descriptor(source: string, ordinal: number): MermaidBlockDescriptor {
    if (this.theme === undefined) {
      throw new Error("Mermaid must be initialized before rendering");
    }
    return {
      source,
      ordinal,
      themeGeneration: this.generation,
    };
  }

  isCurrent(descriptor: MermaidBlockDescriptor): boolean {
    return descriptor.themeGeneration === this.generation;
  }

  async render(descriptor: MermaidBlockDescriptor): Promise<MermaidBlockOutcome> {
    if (!this.isCurrent(descriptor)) return { kind: "stale" };

    const cachedSVG = this.memo.get(descriptor.source, descriptor.ordinal);
    if (cachedSVG !== undefined) {
      return { kind: "success", svg: cachedSVG, fromCache: true };
    }

    const inFlightKey = mermaidDescriptorIdentity(descriptor);
    let renderPromise = this.inFlight.get(inFlightKey);
    if (!renderPromise) {
      const renderID = `mermaid-${descriptor.themeGeneration}-${this.nextRenderSequence}`;
      this.nextRenderSequence += 1;
      renderPromise = this.renderFunction(renderID, descriptor.source).then(
        (result) => result.svg,
      );
      this.trackInFlight(inFlightKey, renderPromise);
    }

    try {
      const svg = await renderPromise;
      if (!this.isCurrent(descriptor)) return { kind: "stale" };

      this.memo.set(descriptor.source, descriptor.ordinal, svg);
      return { kind: "success", svg, fromCache: false };
    } catch (error) {
      if (!this.isCurrent(descriptor)) return { kind: "stale" };
      return {
        kind: "error",
        message: error instanceof Error ? error.message : String(error),
      };
    } finally {
      if (this.inFlight.get(inFlightKey) === renderPromise) {
        this.inFlight.delete(inFlightKey);
      }
    }
  }

  private trackInFlight(key: string, promise: Promise<string>): void {
    while (this.inFlight.size >= this.inFlightCapacity) {
      const oldestKey = this.inFlight.keys().next().value;
      if (oldestKey === undefined) break;
      this.inFlight.delete(oldestKey);
    }
    this.inFlight.set(key, promise);
  }
}

interface MermaidDataset {
  mermaidGeneration?: string;
  mermaidOrdinal?: string;
  mermaidSource?: string;
}

interface ClassListReader {
  contains(token: string): boolean;
}

interface ClassListWriter extends ClassListReader {
  add(...tokens: string[]): void;
  remove(...tokens: string[]): void;
}

export interface MermaidWrapperLike {
  classList: ClassListWriter;
  dataset: MermaidDataset;
  innerHTML: string;
  textContent: string | null;
}

export interface PreviewPatchElementLike {
  classList: ClassListReader;
  className: string;
  dataset: MermaidDataset;
  matches(selector: string): boolean;
  textContent: string | null;
}

export function markMermaidWrapperPending(
  wrapper: MermaidWrapperLike,
  descriptor: MermaidBlockDescriptor,
): void {
  wrapper.classList.add("mermaid-rendered", "mermaid-pending");
  wrapper.dataset.mermaidSource = descriptor.source;
  wrapper.dataset.mermaidOrdinal = String(descriptor.ordinal);
  wrapper.dataset.mermaidGeneration = String(descriptor.themeGeneration);
}

export function applyMermaidBlockOutcome(
  wrapper: MermaidWrapperLike,
  descriptor: MermaidBlockDescriptor,
  outcome: MermaidBlockOutcome,
): boolean {
  if (
    outcome.kind === "stale" ||
    !wrapper.classList.contains("mermaid-pending") ||
    !mermaidWrapperMatchesDescriptor(wrapper, descriptor)
  ) {
    return false;
  }

  wrapper.classList.remove("mermaid-pending", "mermaid-error");
  if (outcome.kind === "success") {
    wrapper.innerHTML = outcome.svg;
  } else {
    wrapper.classList.add("mermaid-error");
    wrapper.textContent = outcome.message;
  }
  return true;
}

export function shouldUpdatePreviewElement(
  fromElement: PreviewPatchElementLike,
  toElement: PreviewPatchElementLike,
): boolean {
  if (shouldPreserveMermaidWrapper(fromElement, toElement)) {
    return false;
  }
  if (!fromElement.matches("pre code") || !toElement.matches("pre code")) {
    return true;
  }
  return (
    fromElement.textContent !== toElement.textContent ||
    codeLanguageClass(fromElement) !== codeLanguageClass(toElement)
  );
}

function mermaidWrapperMatchesDescriptor(
  wrapper: Pick<MermaidWrapperLike, "dataset">,
  descriptor: MermaidBlockDescriptor,
): boolean {
  return (
    wrapper.dataset.mermaidSource === descriptor.source &&
    wrapper.dataset.mermaidOrdinal === String(descriptor.ordinal) &&
    wrapper.dataset.mermaidGeneration === String(descriptor.themeGeneration)
  );
}

function shouldPreserveMermaidWrapper(
  fromElement: PreviewPatchElementLike,
  toElement: PreviewPatchElementLike,
): boolean {
  if (
    !fromElement.classList.contains("mermaid-rendered") ||
    fromElement.classList.contains("mermaid-error") ||
    fromElement.classList.contains("mermaid-pending") ||
    !toElement.classList.contains("mermaid-rendered") ||
    !toElement.classList.contains("mermaid-pending")
  ) {
    return false;
  }

  const source = fromElement.dataset.mermaidSource;
  return (
    source !== undefined &&
    source === toElement.dataset.mermaidSource &&
    fromElement.dataset.mermaidOrdinal === toElement.dataset.mermaidOrdinal &&
    fromElement.dataset.mermaidGeneration === toElement.dataset.mermaidGeneration
  );
}

function codeLanguageClass(element: PreviewPatchElementLike): string {
  return (
    element.className
      .split(/\s+/u)
      .find(
        (className) =>
          className.startsWith("language-") || className.startsWith("lang-"),
      ) ?? ""
  );
}

function mermaidMemoLookupKey(source: string, ordinal: number): string {
  return JSON.stringify([ordinal, source]);
}

function mermaidDescriptorIdentity(descriptor: MermaidBlockDescriptor): string {
  return JSON.stringify([
    descriptor.themeGeneration,
    descriptor.ordinal,
    descriptor.source,
  ]);
}
