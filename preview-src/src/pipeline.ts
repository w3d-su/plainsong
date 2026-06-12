import rehypeKatex from "rehype-katex";
import rehypeStringify from "rehype-stringify";
import remarkFrontmatter from "remark-frontmatter";
import remarkGfm from "remark-gfm";
import remarkMath from "remark-math";
import remarkParse from "remark-parse";
import remarkRehype from "remark-rehype";
import { unified } from "unified";

interface SourcePosition {
  start?: {
    line?: number;
  };
}

interface TreeNode {
  type?: string;
  tagName?: string;
  value?: string;
  properties?: Record<string, unknown>;
  children?: TreeNode[];
  position?: SourcePosition;
}

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

export async function renderMarkdown(markdown: string): Promise<string> {
  const file = await unified()
    .use(remarkParse)
    .use(remarkGfm)
    .use(remarkFrontmatter, ["yaml"])
    .use(stripFrontmatter)
    .use(remarkMath)
    .use(remarkRehype)
    .use(rehypeKatex)
    .use(rehypeSourceLines)
    .use(rehypeStringify)
    .process(markdown);

  return String(file);
}

function stripFrontmatter() {
  return (tree: TreeNode) => {
    if (!tree.children) return;

    tree.children = tree.children.filter(
      (child) => child.type !== "yaml" && child.type !== "toml",
    );
  };
}

function rehypeSourceLines() {
  return (tree: TreeNode) => {
    visit(tree, (node) => {
      if (node.type !== "element" || !node.tagName) return;

      const line = node.position?.start?.line;
      if (line && blockTags.has(node.tagName)) {
        node.properties = node.properties ?? {};
        node.properties.dataLine = String(line);
      }

      if (node.tagName === "input" && node.properties?.type === "checkbox") {
        delete node.properties.disabled;
        node.properties.dataTaskCheckbox = "true";
      }
    });
  };
}

function visit(node: TreeNode, visitor: (node: TreeNode) => void): void {
  visitor(node);

  for (const child of node.children ?? []) {
    visit(child, visitor);
  }
}
