import rehypeKatex from "rehype-katex";
import rehypeSanitize from "rehype-sanitize";
import rehypeStringify from "rehype-stringify";
import remarkGfm from "remark-gfm";
import remarkMath from "remark-math";
import remarkMdx from "remark-mdx";
import remarkParse from "remark-parse";
import remarkRehype from "remark-rehype";
import { unified } from "unified";
import type { VFile } from "vfile";
import type { PreviewFileKind } from "./bridge";
import { remarkClosedFrontmatter } from "./frontmatter";
import {
  type HeadingSlugFileData,
  rehypeHeadingAnchors,
} from "./heading-anchors";
import {
  katexRenderOptions,
  rehypeMathBlocks,
  rehypeMathDiagnostics,
} from "./math";
import {
  mdxSanitizeSchema,
  remarkMdxPlaceholders,
  type TreeNode,
} from "./mdx-placeholders";
import { closerForOpenNode, type SegmentCloser } from "./segment-closers";
import {
  holeMarker,
  requireWholeDocument,
  type SegmentHoleOptions,
  splitHoles,
  type WholeDocumentFileData,
} from "./segment-holes";

const blockTags = new Set([
  "address",
  "article",
  "aside",
  "blockquote",
  "dd",
  "details",
  "div",
  "dl",
  "dt",
  "figcaption",
  "figure",
  "footer",
  "h1",
  "h2",
  "h3",
  "h4",
  "h5",
  "h6",
  "header",
  "hr",
  "li",
  "main",
  "ol",
  "p",
  "pre",
  "section",
  "table",
  "tbody",
  "td",
  "th",
  "thead",
  "tr",
  "ul",
]);

const scriptLikeTags = new Set([
  "base",
  "embed",
  "iframe",
  "link",
  "meta",
  "object",
  "script",
  "style",
]);

const sourceSvgTags = new Set([
  "path",
  "svg",
]);

export async function renderMarkdown(markdown: string): Promise<string> {
  return (await renderWholeDocument("md", markdown)).html;
}

export async function renderMdx(markdown: string): Promise<string> {
  return (await renderWholeDocument("mdx", markdown)).html;
}

/** A whole-document render. `requiresWhole`: the document has a construct a segmented render
 * cannot reproduce (a definition, an unplaced KaTeX message). */
export async function renderWholeDocument(
  fileKind: PreviewFileKind,
  text: string,
): Promise<{ html: string; requiresWhole: boolean }> {
  const file = await (fileKind === "md" ? markdownProcessor : mdxProcessor).process(text);
  return { html: String(file), requiresWhole: (file.data as WholeDocumentFileData).requiresWhole ?? false };
}

/** One segment's HTML with assembly holes (segmented-render.ts). */
export interface RenderedSegment {
  /** `splitHoles` output: text, then kind/value/text triples. */
  pieces: string[];
  /** remark-rehype made at least one root node, even if the MDX pipeline then dropped all of
   * them. The whole render joins root nodes with newlines before any are dropped. */
  hasBlocks: boolean;
  /** Base slugs of the generated heading IDs, in order. */
  headingSlugs: string[];
  /** Math wrappers (`data-math-index` values) in the segment. */
  mathCount: number;
  /** MDX: the segment has ESM. Each ESM block is parsed after `var <earlier imports>`,
   * so whether it parses depends on the imports of earlier segments. */
  hasEsm: boolean;
  /** MDX: the segment's ESM imports a binding. */
  importsBindings: boolean;
}

/** Thrown when a construct in the segment is still open where the next one starts.
 * `closer` says how the construct ends, when it is one that can be found by text. */
export class SegmentBoundaryOpen extends Error {
  constructor(readonly closer?: SegmentCloser) {
    super("segment boundary inside an open construct");
  }
}

/**
 * Renders `text` in segment mode. When another segment follows, pass the segment-relative
 * line it starts on: the text is parsed with a sentinel paragraph on that line, which must
 * come back as a top-level paragraph of its own, proving that nothing was left open.
 * The line is one more than the number of line feeds in `text`.
 * Throws `SegmentBoundaryOpen`, `WholeDocumentRequired`, or a parse error.
 */
export function renderSegment(
  fileKind: PreviewFileKind,
  text: string,
  nextSegmentLine?: number,
): RenderedSegment {
  const data: SegmentFileData = { nextSegmentLine };
  const processor = fileKind === "md" ? markdownSegmentProcessor : mdxSegmentProcessor;
  const file = processor.processSync({
    value: nextSegmentLine === undefined ? text : text + segmentSentinel,
    data,
  });
  const fileData = file.data as SegmentFileData & HeadingSlugFileData & { mathProvenance?: unknown[] };
  return {
    pieces: splitHoles(String(file)),
    hasBlocks: fileData.hasBlocks ?? false,
    headingSlugs: fileData.headingSlugs ?? [],
    mathCount: fileData.mathProvenance?.length ?? 0,
    hasEsm: fileData.hasEsm ?? false,
    importsBindings: fileData.importsBindings ?? false,
  };
}

const segmentSentinel = "plainsongsegmentsentinel";

interface EsmNode {
  data?: { estree?: { body?: Array<{ type: string; specifiers?: unknown[] }> } };
}

interface SegmentFileData extends Record<string, unknown> {
  nextSegmentLine?: number;
  hasBlocks?: boolean;
  hasEsm?: boolean;
  importsBindings?: boolean;
}

const markdownProcessor = createMarkdownProcessor({ holes: false });
const markdownSegmentProcessor = createMarkdownProcessor({ holes: true });
const mdxProcessor = createMdxProcessor({ holes: false });
const mdxSegmentProcessor = createMdxProcessor({ holes: true });

function createMarkdownProcessor(options: SegmentHoleOptions) {
  return unified()
    .use(remarkParse)
    .use(remarkGfm)
    .use(remarkClosedFrontmatter)
    .use(stripFrontmatter)
    .use(remarkMath)
    .use(remarkSegmentBoundary, options)
    .use(remarkRehype)
    .use(rehypeSegmentBlocks, options)
    .use(rehypeHeadingAnchors, options)
    // Wrap display math before KaTeX consumes the positioned pre/code nodes;
    // diagnostics append after KaTeX so VFile messages exist.
    .use(rehypeMathBlocks, options)
    .use(rehypeKatex, katexRenderOptions)
    .use(rehypeMathDiagnostics, options)
    .use(rehypeSourceLines, options)
    .use(rehypeStringify);
}

function createMdxProcessor(options: SegmentHoleOptions) {
  return unified()
    .use(remarkParse)
    .use(remarkMdx)
    .use(remarkGfm)
    .use(remarkClosedFrontmatter)
    .use(stripFrontmatter)
    .use(remarkMath)
    .use(remarkSegmentBoundary, options)
    .use(remarkMdxPlaceholders)
    .use(remarkRehype)
    .use(rehypeSegmentBlocks, options)
    .use(rehypeDropSourceSvgElements)
    .use(rehypeDropScriptLikeElements)
    .use(rehypeSanitize, mdxSanitizeSchema)
    .use(rehypeHeadingAnchors, options)
    // Sanitize user content before trusted KaTeX adds layout styles and generated SVG.
    .use(rehypeMathBlocks, options)
    .use(rehypeKatex, katexRenderOptions)
    .use(rehypeMathDiagnostics, options)
    .use(rehypeSourceLines, options)
    .use(rehypeStringify);
}

/** Finds definitions, which resolve references in every other segment: segment mode refuses
 * them and whole mode records them (`requireWholeDocument`). Segment mode also checks and
 * removes the sentinel and records the segment's ESM. */
function remarkSegmentBoundary(options: SegmentHoleOptions) {
  return (tree: TreeNode, file: VFile) => {
    const data = file.data as SegmentFileData;
    if (!options.holes) {
      // Every definition has `]:` after its label.
      if (String(file.value).includes("]:") && hasDefinition(tree)) requireWholeDocument(file, options, "definition");
      return;
    }
    const line = data.nextSegmentLine;
    if (line !== undefined) {
      const sentinel = tree.children?.at(-1);
      const text = sentinel?.children?.length === 1 ? sentinel.children[0] : undefined;
      if (
        sentinel?.type !== "paragraph" ||
        text?.type !== "text" ||
        text.value !== segmentSentinel ||
        sentinel.position?.start?.line !== line ||
        sentinel.position.start.column !== 1
      ) {
        // The last top-level node holds the sentinel: it is the construct still open.
        const open = tree.children?.at(-1);
        throw new SegmentBoundaryOpen(
          open && closerForOpenNode(open.type, String(file.value), open.position?.start?.offset),
        );
      }
      tree.children?.pop();
    }
    visitTree(tree, (node) => {
      if (isDefinition(node)) requireWholeDocument(file, options, node.type);
      if (node.type === "mdxjsEsm") {
        data.hasEsm = true;
        const body = (node as EsmNode).data?.estree?.body ?? [];
        if (body.some((statement) => statement.type === "ImportDeclaration" && (statement.specifiers?.length ?? 0) > 0)) {
          data.importsBindings = true;
        }
      }
    });
  };
}

function isDefinition(node: TreeNode): boolean {
  return node.type === "definition" || node.type === "footnoteDefinition";
}

function hasDefinition(node: TreeNode): boolean {
  return isDefinition(node) || (node.children ?? []).some(hasDefinition);
}

/** Segment mode only: whether remark-rehype made any root node. The MDX pipeline may drop
 * them all (sanitizing, script-like and source SVG elements) after the root's nodes have
 * been joined with newlines, so assembly cannot tell from the HTML alone. */
function rehypeSegmentBlocks(options: SegmentHoleOptions) {
  if (!options.holes) return;
  return (tree: TreeNode, file: VFile) => {
    (file.data as SegmentFileData).hasBlocks = (tree.children?.length ?? 0) > 0;
  };
}

function stripFrontmatter() {
  return (tree: TreeNode) => {
    if (!tree.children) return;

    tree.children = tree.children.filter(
      (child) => child.type !== "yaml" && child.type !== "toml",
    );
  };
}

function rehypeSourceLines(options: SegmentHoleOptions) {
  return (tree: TreeNode) => {
    visitTree(tree, (node) => {
      if (node.type !== "element" || !node.tagName) return;

      const line = node.position?.start?.line;
      if (line && blockTags.has(node.tagName)) {
        node.properties = node.properties ?? {};
        node.properties.dataLine = options.holes ? holeMarker("L", line) : String(line);
      }

      // Only rehypeMathBlocks writes this attribute (sanitizing drops a user's).
      const mathIndex = node.properties?.dataMathIndex;
      if (options.holes && typeof mathIndex === "string") {
        node.properties!.dataMathIndex = holeMarker("M", Number(mathIndex));
      }

      if (node.tagName === "input" && node.properties?.type === "checkbox") {
        delete node.properties.disabled;
        node.properties.dataTaskCheckbox = "true";
      }
    });
  };
}

function rehypeDropScriptLikeElements() {
  return (tree: TreeNode) => {
    dropChildrenByTagName(tree, scriptLikeTags);
  };
}

function rehypeDropSourceSvgElements() {
  return (tree: TreeNode) => {
    dropChildrenByTagName(tree, sourceSvgTags);
  };
}

function dropChildrenByTagName(node: TreeNode, tagNames: Set<string>): void {
  if (!node.children) return;

  node.children = node.children.filter((child) => {
    if (child.type !== "element" || !child.tagName) return true;
    return !tagNames.has(child.tagName.toLowerCase());
  });

  for (const child of node.children) {
    dropChildrenByTagName(child, tagNames);
  }
}

function visitTree(node: TreeNode, visitor: (node: TreeNode) => void): void {
  visitor(node);

  for (const child of node.children ?? []) {
    visitTree(child, visitor);
  }
}
