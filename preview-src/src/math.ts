import type { VFile } from "vfile";
import type { VFileMessage } from "vfile-message";
import type { TreeNode } from "./mdx-placeholders";

// Shared KaTeX settings for both pipelines (docs/math plan §3.4):
// - trust:false keeps \url, \href, \includegraphics and \html* disabled.
// - htmlAndMathml keeps the MathML tree for assistive technology.
// - strict:"ignore" renders LaTeX-incompatible but renderable input (e.g. CJK
//   text in math mode) silently. "warn" only logged to the WKWebView console on
//   every debounced render and never reached the preview, because rehype-katex
//   records only thrown errors as VFile messages.
// - maxExpand caps macro expansion; maxSize caps user-specified sizes in em.
// displayMode/throwOnError stay with rehype-katex 7: it derives display mode per
// node and catches errors itself, recording them as VFile diagnostics.
export const katexRenderOptions = {
  trust: false,
  output: "htmlAndMathml",
  strict: "ignore",
  maxExpand: 1000,
  maxSize: 20,
} as const;

const mathBlockClass = "plainsong-math-block";
const mathInlineClass = "plainsong-math-inline";
const mathErrorHintClass = "math-error-hint";
const mathErrorHintLimit = 140;
const mathIndexAttribute = "dataMathIndex";

interface MathProvenance {
  index: number;
  offset: number | undefined;
}

interface MathFileData extends Record<string, unknown> {
  mathProvenance?: MathProvenance[];
}

// rehype-katex replaces the whole `pre`/`code` for math, dropping the source
// position that scroll sync needs. Wrap every math node before KaTeX runs:
// `pre > code.{language-math, math-display}` gets a `div.plainsong-math-block`
// (data-line/data-line-end kept from the source position) and inline
// `code.math-inline` gets a `span.plainsong-math-inline`. Each wrapper carries
// a `data-math-index` so post-KaTeX diagnostics can pair VFile messages back to
// their formula — required for parse errors such as unknown commands, which
// rehype-katex re-renders as normal (red) KaTeX markup without any
// `.katex-error` element to find.
//
// `$$` flow math gives its `code` no position (only the `pre` has one); the
// pre's position is copied onto the code so the VFile message's `place` is set.
export function rehypeMathBlocks() {
  return (tree: TreeNode, file: VFile) => {
    const provenance: MathProvenance[] = [];
    wrapMathNodes(tree, provenance);
    (file.data as MathFileData).mathProvenance = provenance;
  };
}

// Localize KaTeX failures: each rehype-katex VFile message pairs with the math
// wrapper at its `place` position. The hint is a text node (not hover-only, not
// color-only) while the rendered output keeps the full selectable source. A
// message without a resolvable place falls back to the remaining unhinted
// `.katex-error` elements.
export function rehypeMathDiagnostics() {
  return (tree: TreeNode, file: VFile) => {
    const messages = file.messages.filter((message) => message.source === "rehype-katex");
    if (messages.length === 0) return;

    const provenance = (file.data as MathFileData).mathProvenance ?? [];
    const wrappers = collectMathWrappers(tree);
    const hinted = new Set<number>();
    const orphans: VFileMessage[] = [];

    for (const message of messages) {
      const wrapper = wrapperFor(message, provenance, wrappers);
      if (wrapper === undefined) {
        orphans.push(message);
        continue;
      }
      if (!hinted.has(wrapper.index)) {
        appendHint(wrapper.node, mathErrorHint(message));
        hinted.add(wrapper.index);
      }
    }

    annotateOrphanErrors(tree, orphans, hinted);
  };
}

interface MathWrapper {
  index: number;
  node: TreeNode;
}

function wrapMathNodes(parent: TreeNode, provenance: MathProvenance[]): void {
  const children = parent.children;
  if (!children) return;

  for (let index = 0; index < children.length; index += 1) {
    const child = children[index];
    if (isDisplayMathPre(child)) {
      // `$$` flow math leaves the inner `code` unpositioned; copy the `pre`
      // position so rehype-katex's `place: element.position` still resolves.
      const code = displayMathCode(child);
      if (code && !code.position && child.position) {
        code.position = child.position;
      }
      children[index] = wrapNode(child, "div", mathBlockClass, provenance, {
        withEndLine: true,
      });
      continue;
    }
    if (isInlineMathCode(child)) {
      children[index] = wrapNode(child, "span", mathInlineClass, provenance, {
        withEndLine: false,
      });
      continue;
    }
    wrapMathNodes(child, provenance);
  }
}

function wrapNode(
  node: TreeNode,
  tagName: string,
  className: string,
  provenance: MathProvenance[],
  options: { withEndLine: boolean },
): TreeNode {
  const index = provenance.length;
  provenance.push({ index, offset: node.position?.start?.offset });

  const properties: Record<string, unknown> = {
    className: [className],
    [mathIndexAttribute]: String(index),
  };
  const startLine = node.position?.start?.line;
  const endLine = node.position?.end?.line;
  if (startLine !== undefined) properties.dataLine = String(startLine);
  if (options.withEndLine && endLine !== undefined) properties.dataLineEnd = String(endLine);

  return {
    type: "element",
    tagName,
    properties,
    position: node.position,
    children: [node],
  };
}

function isDisplayMathPre(node: TreeNode): boolean {
  return displayMathCode(node) !== undefined;
}

function displayMathCode(node: TreeNode): TreeNode | undefined {
  if (node.type !== "element" || node.tagName !== "pre") return undefined;
  const content = (node.children ?? []).filter(
    (child) => child.type !== "text" || (child.value ?? "").trim() !== "",
  );
  if (content.length !== 1) return undefined;
  const code = content[0];
  if (code.type !== "element" || code.tagName !== "code") return undefined;
  const classes = Array.isArray(code.properties?.className) ? code.properties.className : [];
  return classes.includes("language-math") || classes.includes("math-display") ? code : undefined;
}

function isInlineMathCode(node: TreeNode): boolean {
  if (node.type !== "element" || node.tagName !== "code") return false;
  const classes = Array.isArray(node.properties?.className) ? node.properties.className : [];
  return classes.includes("math-inline");
}

function collectMathWrappers(tree: TreeNode): Map<number, TreeNode> {
  const wrappers = new Map<number, TreeNode>();
  visitNodes(tree, (node) => {
    const index = mathIndexOf(node);
    if (index !== undefined) wrappers.set(index, node);
  });
  return wrappers;
}

function mathIndexOf(node: TreeNode): number | undefined {
  if (node.type !== "element") return undefined;
  const raw = node.properties?.[mathIndexAttribute];
  if (raw === undefined) return undefined;
  const index = Number(raw);
  return Number.isInteger(index) ? index : undefined;
}

function wrapperFor(
  message: VFileMessage,
  provenance: MathProvenance[],
  wrappers: Map<number, TreeNode>,
): MathWrapper | undefined {
  const offset = messageOffset(message);
  const entry = offset === undefined
    ? undefined
    : provenance.find((candidate) => candidate.offset === offset);
  if (entry === undefined) return undefined;
  const node = wrappers.get(entry.index);
  return node === undefined ? undefined : { index: entry.index, node };
}

function messageOffset(message: VFileMessage): number | undefined {
  const place = message.place as
    | { start?: { offset?: number }; offset?: number }
    | undefined;
  return place?.start?.offset ?? place?.offset;
}

// Fallback for messages whose place could not be resolved: pair them, in
// order, with `.katex-error` descendants of still-unhinted math wrappers. Each
// message is consumed once; a wrapper gets at most one hint, attached to the
// wrapper itself; errors left after the messages run out get a generic hint.
function annotateOrphanErrors(
  tree: TreeNode,
  messages: VFileMessage[],
  hinted: Set<number>,
): void {
  if (messages.length === 0) return;
  annotateOrphanErrorsIn(tree, [...messages], hinted, undefined);
}

function annotateOrphanErrorsIn(
  node: TreeNode,
  remaining: VFileMessage[],
  hinted: Set<number>,
  enclosing: MathWrapper | undefined,
): void {
  const children = node.children;
  if (!children) return;

  const index = mathIndexOf(node);
  const wrapper = index === undefined ? enclosing : { index, node };
  if (wrapper !== undefined && hinted.has(wrapper.index)) return;

  for (const child of children) {
    if (isKatexError(child)) {
      appendHint(wrapper?.node ?? node, mathErrorHint(takeMessage(child, remaining)));
      if (wrapper !== undefined) {
        hinted.add(wrapper.index);
        return;
      }
      continue;
    }
    annotateOrphanErrorsIn(child, remaining, hinted, wrapper);
  }
}

function takeMessage(element: TreeNode, remaining: VFileMessage[]): VFileMessage | undefined {
  const message = matchMessage(element, remaining) ?? remaining[0];
  if (message !== undefined) remaining.splice(remaining.indexOf(message), 1);
  return message;
}

function appendHint(wrapper: TreeNode, hint: TreeNode): void {
  wrapper.children = [...(wrapper.children ?? []), hint];
}

function isKatexError(node: TreeNode): boolean {
  if (node.type !== "element") return false;
  const classes = Array.isArray(node.properties?.className) ? node.properties.className : [];
  return classes.includes("katex-error");
}

function matchMessage(element: TreeNode, messages: VFileMessage[]): VFileMessage | undefined {
  const title = String(element.properties?.title ?? "");
  return (
    messages.find((message) => String(message.cause) === title) ??
    messages.find((message) => title.includes(String(message.cause)))
  );
}

// KaTeX appends ` at position N: <source with U+0332 underlines>` (plus a
// trailing newline-underline for fences) to parse errors; keep only the description.
function hintDescription(detail: string): string {
  return detail
    .replace(/ at position \d+:[\s\S]*$/u, "")
    .replace(/̲/gu, "")
    .trim();
}

function mathErrorHint(message: VFileMessage | undefined): TreeNode {
  const cause = message?.cause;
  const detail =
    cause instanceof Error
      ? cause.message.replace(/^KaTeX parse error:\s*/u, "")
      : undefined;
  const description = detail === undefined ? undefined : hintDescription(detail);
  const text = description
    ? `KaTeX: ${truncate(description, mathErrorHintLimit)}`
    : "KaTeX could not render this formula";
  return {
    type: "element",
    tagName: "span",
    properties: { className: [mathErrorHintClass], role: "note" },
    children: [{ type: "text", value: text }],
  };
}

function visitNodes(node: TreeNode, visitor: (node: TreeNode) => void): void {
  visitor(node);
  for (const child of node.children ?? []) {
    visitNodes(child, visitor);
  }
}

function truncate(value: string, limit: number): string {
  if (value.length <= limit) return value;
  return `${value.slice(0, Math.max(0, limit - 1))}…`;
}
