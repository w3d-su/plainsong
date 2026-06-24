import rehypeKatex from "rehype-katex";
import rehypeSanitize from "rehype-sanitize";
import rehypeStringify from "rehype-stringify";
import remarkFrontmatter from "remark-frontmatter";
import remarkGfm from "remark-gfm";
import remarkMath from "remark-math";
import remarkMdx from "remark-mdx";
import remarkParse from "remark-parse";
import remarkRehype from "remark-rehype";
import { unified } from "unified";
import {
  mdxSanitizeSchema,
  remarkMdxPlaceholders,
  type TreeNode,
} from "./mdx-placeholders";

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
  return String(await markdownProcessor.process(markdown));
}

export async function renderMdx(markdown: string): Promise<string> {
  return String(await mdxProcessor.process(markdown));
}

const markdownProcessor = unified()
  .use(remarkParse)
  .use(remarkGfm)
  .use(remarkFrontmatter, ["yaml"])
  .use(stripFrontmatter)
  .use(remarkMath)
  .use(remarkRehype)
  .use(rehypeKatex)
  .use(rehypeSourceLines)
  .use(rehypeStringify);

const mdxProcessor = unified()
  .use(remarkParse)
  .use(remarkMdx)
  .use(remarkGfm)
  .use(remarkFrontmatter, ["yaml"])
  .use(stripFrontmatter)
  .use(remarkMath)
  .use(remarkMdxPlaceholders)
  .use(remarkRehype)
  .use(rehypeDropSourceSvgElements)
  .use(rehypeKatex)
  .use(rehypeSourceLines)
  .use(rehypeDropScriptLikeElements)
  .use(rehypeSanitize, mdxSanitizeSchema)
  .use(rehypeStringify);

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
    visitTree(tree, (node) => {
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
