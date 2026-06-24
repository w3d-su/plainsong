import { defaultSchema, type Options as SanitizeSchema } from "rehype-sanitize";
import type {
  MdxJsxAttribute,
  MdxJsxAttributeValueExpression,
  MdxJsxExpressionAttribute,
  MdxJsxFlowElement,
  MdxJsxTextElement,
  MdxjsEsm,
  MdxFlowExpression,
  MdxTextExpression,
} from "mdast-util-mdx";
import type { Position } from "unist";

type SourcePosition = Position;

export interface TreeNode {
  type: string;
  tagName?: string;
  value?: string;
  properties?: Record<string, unknown>;
  children?: TreeNode[];
  position?: SourcePosition;
  data?: {
    hName?: string;
    hProperties?: Record<string, unknown>;
    hChildren?: TreeNode[];
  };
}

const componentPropLimit = 96;
const componentPropCountLimit = 4;
const esmPreviewLimit = 120;
const expressionPreviewLimit = 96;
const safeClassNameRule: [string, RegExp] = ["className", /^[A-Za-z0-9_-]+$/];
const unsafePreviewAttributes = new Set(["height", "style", "width"]);

export const mdxSanitizeSchema: SanitizeSchema = {
  ...defaultSchema,
  required: {
    ...defaultSchema.required,
    input: { type: "checkbox" },
  },
  attributes: {
    ...defaultSchema.attributes,
    "*": [
      ...safeSanitizeAttributes(defaultSchema.attributes?.["*"]),
      "dataLine",
      "dataTaskCheckbox",
      safeClassNameRule,
      "ariaHidden",
    ],
    a: [...safeSanitizeAttributes(defaultSchema.attributes?.a), "href", "title"],
    code: [
      ...safeSanitizeAttributes(defaultSchema.attributes?.code).filter((attribute) => {
        const name = typeof attribute === "string" ? attribute : attribute[0];
        return name !== "className";
      }),
      safeClassNameRule,
    ],
    div: [...safeSanitizeAttributes(defaultSchema.attributes?.div)],
    input: [
      ...safeSanitizeAttributes(defaultSchema.attributes?.input),
      ["type", "checkbox"],
      "checked",
      "disabled",
      "dataTaskCheckbox",
    ],
    img: [...safeSanitizeAttributes(defaultSchema.attributes?.img), "alt", "title"],
    li: [...safeSanitizeAttributes(defaultSchema.attributes?.li)],
    math: [
      "xmlns",
      "display",
      "overflow",
      "alttext",
      "altimg",
      "altimgWidth",
      "altimgHeight",
      "altimgValign",
    ],
    mi: ["mathvariant"],
    mn: [],
    mo: ["stretchy", "fence", "lspace", "rspace", "separator"],
    mrow: [],
    mtext: [],
    msup: [],
    msub: [],
    msubsup: [],
    mfrac: ["linethickness"],
    mtable: ["rowspacing", "columnalign", "columnspacing"],
    mtr: [],
    mtd: [],
    mover: ["accent"],
    mstyle: ["scriptlevel", "displaystyle"],
    semantics: [],
    annotation: ["encoding"],
    span: [...safeSanitizeAttributes(defaultSchema.attributes?.span), safeClassNameRule, "ariaHidden"],
  },
  tagNames: [
    ...(defaultSchema.tagNames ?? []),
    "math",
    "mi",
    "mn",
    "mo",
    "mrow",
    "mtext",
    "msup",
    "msub",
    "msubsup",
    "mfrac",
    "mtable",
    "mtr",
    "mtd",
    "mover",
    "mstyle",
    "semantics",
    "annotation",
  ],
};

function safeSanitizeAttributes(
  attributes: NonNullable<SanitizeSchema["attributes"]>[string] = [],
): NonNullable<SanitizeSchema["attributes"]>[string] {
  return attributes.filter((attribute) => {
    const name = Array.isArray(attribute) ? attribute[0] : attribute;
    return !(typeof name === "string" && unsafePreviewAttributes.has(name));
  });
}

export function remarkMdxPlaceholders() {
  return (tree: TreeNode) => {
    rewriteMdxChildren(tree);
  };
}

function rewriteMdxChildren(parent: TreeNode): void {
  if (!parent.children) return;

  for (let index = 0; index < parent.children.length; index += 1) {
    const child = parent.children[index];
    rewriteMdxChildren(child);
    parent.children[index] = rewriteMdxNode(child) ?? child;
  }
}

function rewriteMdxNode(node: TreeNode): TreeNode | undefined {
  switch (node.type) {
    case "mdxjsEsm":
      return mdxEsmPlaceholder(node as MdxjsEsm & TreeNode);
    case "mdxFlowExpression":
      return mdxFlowExpressionPlaceholder(node as MdxFlowExpression & TreeNode);
    case "mdxTextExpression":
      return mdxTextExpressionPlaceholder(node as MdxTextExpression & TreeNode);
    case "mdxJsxFlowElement":
      return mdxElementPlaceholder(node as MdxJsxFlowElement & TreeNode, "flow");
    case "mdxJsxTextElement":
      return mdxElementPlaceholder(node as MdxJsxTextElement & TreeNode, "text");
    default:
      return undefined;
  }
}

function mdxEsmPlaceholder(node: MdxjsEsm & TreeNode): TreeNode {
  return hastBackedNode(
    "mdxEsmPlaceholder",
    "div",
    { className: ["mdx-esm-placeholder"] },
    [textNode(`⟨${truncate(oneLine(node.value), esmPreviewLimit)}⟩`)],
    node.position,
  );
}

function mdxFlowExpressionPlaceholder(node: MdxFlowExpression & TreeNode): TreeNode {
  return hastBackedNode(
    "mdxExpressionRow",
    "p",
    { className: ["mdx-expression-row"] },
    [mdxExpressionChip(node.value, node.position)],
    node.position,
  );
}

function mdxTextExpressionPlaceholder(node: MdxTextExpression & TreeNode): TreeNode {
  return mdxExpressionChip(node.value, node.position);
}

function mdxExpressionChip(value: string, position?: SourcePosition): TreeNode {
  return hastBackedNode(
    "mdxExpressionChip",
    "code",
    { className: ["mdx-expression-chip"] },
    [textNode(`{${truncate(oneLine(value), expressionPreviewLimit)}}`)],
    position,
  );
}

function mdxElementPlaceholder(
  node: (MdxJsxFlowElement | MdxJsxTextElement) & TreeNode,
  placement: "flow" | "text",
): TreeNode {
  const name = node.name ?? "Fragment";
  if (isLowercaseHtmlName(name)) {
    return lowercaseHtmlElement(node, placement);
  }

  return componentCard(node, name, placement);
}

function lowercaseHtmlElement(
  node: (MdxJsxFlowElement | MdxJsxTextElement) & TreeNode,
  placement: "flow" | "text",
): TreeNode {
  return hastBackedNode(
    "mdxLowercaseElement",
    node.name ?? (placement === "flow" ? "div" : "span"),
    lowercaseHtmlProperties(node.attributes),
    node.children as TreeNode[],
    node.position,
  );
}

function componentCard(
  node: (MdxJsxFlowElement | MdxJsxTextElement) & TreeNode,
  name: string,
  placement: "flow" | "text",
): TreeNode {
  const hasChildren = node.children.length > 0;
  const containerName = placement === "flow" ? "div" : "span";
  const bodyName = placement === "flow" ? "div" : "span";
  const props = componentProps(node.attributes);
  const headerChildren: TreeNode[] = [
    hastBackedNode(
      "mdxComponentName",
      "span",
      { className: ["mdx-component-name"] },
      [textNode(name)],
      node.position,
    ),
  ];

  if (props) {
    headerChildren.push(
      hastBackedNode(
        "mdxComponentProps",
        "code",
        { className: ["mdx-component-props"] },
        [textNode(props)],
        node.position,
      ),
    );
  }

  const children = [
    hastBackedNode(
      "mdxComponentHeader",
      placement === "flow" ? "div" : "span",
      { className: ["mdx-component-header"] },
      headerChildren,
      node.position,
    ),
  ];

  if (hasChildren) {
    children.push(
      hastBackedNode(
        "mdxComponentBody",
        bodyName,
        { className: ["mdx-component-body"] },
        node.children as TreeNode[],
        node.position,
      ),
    );
  }

  return hastBackedNode(
    "mdxComponentCard",
    containerName,
    {
      className: [
        "mdx-component-card",
        placement === "flow" ? "mdx-component-card-flow" : "mdx-component-card-text",
      ],
    },
    children,
    node.position,
  );
}

function componentProps(
  attributes: Array<MdxJsxAttribute | MdxJsxExpressionAttribute>,
): string {
  const props = attributes.slice(0, componentPropCountLimit).map((attribute) => {
    if (attribute.type === "mdxJsxExpressionAttribute") {
      return `{${truncate(oneLine(attribute.value), 32)}}`;
    }

    const value = attribute.value;
    if (value === null || value === undefined) return attribute.name;
    if (typeof value === "string") {
      return `${attribute.name}="${truncate(oneLine(value), 32)}"`;
    }

    return `${attribute.name}={${truncate(oneLine(value.value), 32)}}`;
  });

  if (attributes.length > componentPropCountLimit) {
    props.push("...");
  }

  return truncate(props.join(" "), componentPropLimit);
}

function lowercaseHtmlProperties(
  attributes: Array<MdxJsxAttribute | MdxJsxExpressionAttribute>,
): Record<string, unknown> {
  const properties: Record<string, unknown> = {};

  for (const attribute of attributes) {
    if (attribute.type === "mdxJsxExpressionAttribute") continue;

    const name = normalizeHtmlAttributeName(attribute.name);
    if (!isSafeHtmlAttributeName(name)) continue;

    const value = attribute.value;
    if (value === null || value === undefined) {
      properties[name] = true;
    } else if (typeof value === "string") {
      properties[name] = name === "className" ? value.split(/\s+/u).filter(Boolean) : value;
    } else if (isLiteralMdxAttributeExpression(value)) {
      properties[name] = unquoteLiteralExpression(value.value);
    }
  }

  return properties;
}

function isLiteralMdxAttributeExpression(
  value: MdxJsxAttributeValueExpression,
): value is MdxJsxAttributeValueExpression & { value: string } {
  return /^['"][\s\S]*['"]$/u.test(value.value);
}

function unquoteLiteralExpression(value: string): string {
  return value.slice(1, -1);
}

function normalizeHtmlAttributeName(name: string): string {
  if (name === "class") return "className";
  if (name === "for") return "htmlFor";
  return name;
}

function isSafeHtmlAttributeName(name: string): boolean {
  return (
    /^[A-Za-z][\w:.-]*$/u.test(name) &&
    !/^on/i.test(name) &&
    name !== "dangerouslySetInnerHTML" &&
    name !== "style" &&
    name !== "srcDoc"
  );
}

function isLowercaseHtmlName(name: string): boolean {
  return /^[a-z][\w.-]*$/u.test(name);
}

function hastBackedNode(
  type: string,
  hName: string,
  hProperties: Record<string, unknown>,
  children: TreeNode[],
  position?: SourcePosition,
): TreeNode {
  return {
    type,
    children,
    position,
    data: {
      hName,
      hProperties,
    },
  };
}

function textNode(value: string): TreeNode {
  return { type: "text", value };
}

function oneLine(value: string): string {
  return value.replace(/\s+/gu, " ").trim();
}

function truncate(value: string, limit: number): string {
  if (value.length <= limit) return value;
  return `${value.slice(0, Math.max(0, limit - 1))}…`;
}
