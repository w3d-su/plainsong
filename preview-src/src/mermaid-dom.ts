import morphdom from "morphdom";
import {
  applyMermaidBlockOutcome,
  type MermaidBlockDescriptor,
  MermaidRenderCoordinator,
  markMermaidWrapperPending,
  shouldUpdatePreviewChildren,
  shouldUpdatePreviewElement,
} from "./mermaid-renderer";

export type PreparedMermaidBlocks = ReadonlyArray<
  MermaidBlockDescriptor | undefined
>;

export function patchPreviewRoot(
  liveRoot: HTMLElement,
  nextRoot: HTMLElement,
  coordinator: MermaidRenderCoordinator,
): Promise<void> {
  const descriptors = prepareMermaidBlocks(nextRoot, coordinator);
  const pendingWrappers = new Set<HTMLElement>();

  morphdom(liveRoot, nextRoot, {
    childrenOnly: true,
    onBeforeElUpdated: shouldUpdatePreviewElement,
    onBeforeElChildrenUpdated: shouldUpdatePreviewChildren,
    onElUpdated(element) {
      collectPendingMermaidWrapper(element, pendingWrappers);
    },
    onNodeAdded(node) {
      collectPendingMermaidWrapper(node, pendingWrappers);
    },
  });

  return renderPendingMermaidBlocks(
    liveRoot,
    pendingWrappers,
    descriptors,
    coordinator,
  );
}

export function prepareMermaidBlocks(
  root: ParentNode,
  coordinator: MermaidRenderCoordinator,
): PreparedMermaidBlocks {
  const descriptors: Array<MermaidBlockDescriptor | undefined> = [];
  const blocks = Array.from(
    root.querySelectorAll<HTMLElement>(
      "pre > code.language-mermaid, pre > code.lang-mermaid",
    ),
  );

  for (const [ordinal, code] of blocks.entries()) {
    const pre = code.closest("pre");
    if (!pre) continue;

    const descriptor = coordinator.descriptor(code.textContent ?? "", ordinal);
    const wrapper = document.createElement("div");
    markMermaidWrapperPending(wrapper, descriptor);
    pre.replaceWith(wrapper);
    descriptors[ordinal] = descriptor;
  }

  return descriptors;
}

export function collectPendingMermaidWrapper(
  node: Node,
  pendingWrappers: Set<HTMLElement>,
): void {
  if (
    node instanceof HTMLElement &&
    node.classList.contains("mermaid-rendered") &&
    node.classList.contains("mermaid-pending")
  ) {
    pendingWrappers.add(node);
  }
}

export async function renderPendingMermaidBlocks(
  liveRoot: HTMLElement,
  pendingWrappers: ReadonlySet<HTMLElement>,
  descriptors: PreparedMermaidBlocks,
  coordinator: MermaidRenderCoordinator,
): Promise<void> {
  const pendingBlocks: Array<{
    descriptor: MermaidBlockDescriptor;
    wrapper: HTMLElement;
  }> = [];

  for (const wrapper of pendingWrappers) {
    const ordinal = Number.parseInt(wrapper.dataset.mermaidOrdinal ?? "", 10);
    const descriptor = descriptors[ordinal];
    if (
      !Number.isSafeInteger(ordinal) ||
      !descriptor ||
      wrapper.dataset.mermaidSource !== descriptor.source ||
      wrapper.dataset.mermaidGeneration !==
        String(descriptor.themeGeneration)
    ) {
      continue;
    }
    pendingBlocks.push({ descriptor, wrapper });
  }

  pendingBlocks.sort(
    (left, right) => left.descriptor.ordinal - right.descriptor.ordinal,
  );

  for (const { descriptor, wrapper } of pendingBlocks) {
    const outcome = await coordinator.render(descriptor);
    if (!liveRoot.contains(wrapper)) continue;
    applyMermaidBlockOutcome(wrapper, descriptor, outcome);
  }
}

export async function rerenderVisibleMermaidBlocks(
  liveRoot: HTMLElement,
  coordinator: MermaidRenderCoordinator,
): Promise<void> {
  const descriptors: Array<MermaidBlockDescriptor | undefined> = [];
  const pendingWrappers = new Set<HTMLElement>();

  for (const wrapper of liveRoot.querySelectorAll<HTMLElement>(
    ".mermaid-rendered",
  )) {
    const source = wrapper.dataset.mermaidSource;
    const ordinal = Number.parseInt(wrapper.dataset.mermaidOrdinal ?? "", 10);
    if (source === undefined || !Number.isSafeInteger(ordinal)) continue;

    const descriptor = coordinator.descriptor(source, ordinal);
    markMermaidWrapperPending(wrapper, descriptor);
    descriptors[ordinal] = descriptor;
    pendingWrappers.add(wrapper);
  }

  await renderPendingMermaidBlocks(
    liveRoot,
    pendingWrappers,
    descriptors,
    coordinator,
  );
}
