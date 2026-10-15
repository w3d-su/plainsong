import hljs from "highlight.js/lib/core";
import bash from "highlight.js/lib/languages/bash";
import css from "highlight.js/lib/languages/css";
import go from "highlight.js/lib/languages/go";
import javascript from "highlight.js/lib/languages/javascript";
import json from "highlight.js/lib/languages/json";
import markdown from "highlight.js/lib/languages/markdown";
import python from "highlight.js/lib/languages/python";
import rust from "highlight.js/lib/languages/rust";
import swift from "highlight.js/lib/languages/swift";
import typescript from "highlight.js/lib/languages/typescript";
import xml from "highlight.js/lib/languages/xml";
import yaml from "highlight.js/lib/languages/yaml";

// Language auto-detection runs every registered grammar over the fence, and its
// cost grows superlinearly with line length: a 40,000-char single-line bare fence
// took ~6.7 s in JavaScriptCore (~12.6 s on hosted CI), stalling preview, export
// and Print. At this cap the worst measured case (one 4,000-char line) is ~55 ms
// while ordinary ~100-line snippets still auto-detect (docs/perf-log.md).
// Fences with an explicit language are not affected.
export const AUTO_DETECT_MAX_LENGTH = 4_000;

export function highlightCodeBlocks(root: ParentNode): void {
  for (const code of root.querySelectorAll<HTMLElement>("pre code")) {
    if (code.classList.contains("language-mermaid")) continue;
    if (code.dataset.highlighted) continue;

    if (
      !hasLanguageClass(code) &&
      (code.textContent?.length ?? 0) > AUTO_DETECT_MAX_LENGTH
    ) {
      // Plain text with the highlighted block styling. The language class stays
      // empty so morphdom keeps this DOM while the source is unchanged.
      code.classList.add("hljs");
      code.dataset.highlighted = "yes";
      continue;
    }

    hljs.highlightElement(code);
  }
}

export function registerHighlightLanguages(): void {
  hljs.registerLanguage("bash", bash);
  hljs.registerLanguage("css", css);
  hljs.registerLanguage("go", go);
  hljs.registerLanguage("html", xml);
  hljs.registerLanguage("javascript", javascript);
  hljs.registerLanguage("js", javascript);
  hljs.registerLanguage("json", json);
  hljs.registerLanguage("markdown", markdown);
  hljs.registerLanguage("md", markdown);
  hljs.registerLanguage("python", python);
  hljs.registerLanguage("py", python);
  hljs.registerLanguage("rust", rust);
  hljs.registerLanguage("rs", rust);
  hljs.registerLanguage("sh", bash);
  hljs.registerLanguage("swift", swift);
  hljs.registerLanguage("typescript", typescript);
  hljs.registerLanguage("ts", typescript);
  hljs.registerLanguage("xml", xml);
  hljs.registerLanguage("yaml", yaml);
  hljs.registerLanguage("yml", yaml);
  hljs.registerLanguage("mermaid", markdown);
}

function hasLanguageClass(code: HTMLElement): boolean {
  return Array.from(code.classList).some(
    (className) =>
      className.startsWith("language-") || className.startsWith("lang-"),
  );
}
