import type { Root } from "hast";
import rehypeKatex from "rehype-katex";
import rehypeStringify from "rehype-stringify";
import { unified } from "unified";
import type { VFile } from "vfile";
import type { TreeNode } from "./mdx-placeholders";

declare module "vfile" {
  interface DataMap {
    hasAuthoredHTML?: boolean;
    mathHTML?: string[];
  }
}

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

const renderKatex = rehypeKatex(katexRenderOptions);
const serializer = unified().use(rehypeStringify);

export class MathFragments {
  readonly html: string[] = [];
  private readonly bySource = new Map<string, number>();

  render(wrapper: TreeNode, code: TreeNode, display: boolean, file: VFile): void {
    const children = code.children;
    const source = children?.[0];
    if (children?.length !== 1 || source?.type !== "text" || source.value === undefined) return;
    const scope = wrapper.children![0];
    if (display && (scope.children?.length !== 1 || scope.children[0] !== code)) return;

    const key = (display ? "display:" : "inline:") + source.value;
    let index = this.bySource.get(key);
    if (index === undefined) {
      const fragment = { type: "root", children: [scope] } as Root;
      const before = file.messages.length;
      renderKatex(fragment, file);
      if (file.messages.length !== before) {
        wrapper.children = fragment.children as TreeNode[];
        return;
      }
      index = this.html.length;
      this.html.push(serializer.stringify(fragment));
      this.bySource.set(key, index);
    }
    wrapper.children = [{
      type: "element", tagName: "span", properties: { dataPlainsongMathSlot: String(index) }, children: [],
    }];
  }
}

export class PreviewMathSlots {
  readonly html: string[] = [];
  private readonly byHTML = new Map<string, number>();

  slot(html: string): string {
    let index = this.byHTML.get(html);
    if (index === undefined) {
      index = this.html.length;
      this.html.push(html);
      this.byHTML.set(html, index);
    }
    return `<span data-plainsong-math-slot="${index}"></span>`;
  }
}

export function expandMath(html: string, fragments: string[], slots?: PreviewMathSlots): string {
  if (!fragments.length) return html;
  return html.replace(/<span data-plainsong-math-slot="(\d+)"><\/span>/gu, (_, index: string) => {
    const fragment = fragments[Number(index)];
    return slots ? slots.slot(fragment) : fragment;
  });
}
