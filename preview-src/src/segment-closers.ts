// Where a construct that is still open at a rejected cut ends (segmented-render.ts). Instead of
// trying every later cut inside a long fence, HTML block or MDX element, the renderer skips
// to the line that closes it. A prediction only saves work: the next cut is still checked
// with the sentinel, so a wrong prediction costs one more try, never different output.

/** How an open construct ends. */
export type SegmentCloser =
  /** Fenced code or `$$` math: a line of at least `size` markers after up to three spaces. */
  | { kind: "fence"; marker: "`" | "~" | "$"; size: number }
  /** An HTML block of kinds 1-5: the first line that contains `end`. */
  | { kind: "html"; end: RegExp }
  /** An MDX JSX element: the first line with its closing tag. */
  | { kind: "jsx"; name: string };

/** How the top-level mdast node of `type` whose opening line starts at `offset` in `source`
 * ends, when it is a construct that can swallow the sentinel. */
export function closerForOpenNode(
  type: string,
  source: string,
  offset: number | undefined,
): SegmentCloser | undefined {
  if (offset === undefined) return undefined;
  const lineEnd = source.indexOf("\n", offset);
  const line = source.slice(offset, lineEnd === -1 ? source.length : lineEnd).trimStart();
  if (type === "code" || type === "math") {
    const fence = /^(?:`{3,}|~{3,}|\${2,})/u.exec(line)?.[0];
    return fence === undefined
      ? undefined
      : { kind: "fence", marker: fence[0] as "`" | "~" | "$", size: fence.length };
  }
  if (type === "html") {
    const end = htmlBlockEnd(line);
    return end === undefined ? undefined : { kind: "html", end };
  }
  return undefined;
}

/** The element an MDX "Expected a closing tag for `<Name>`" error is about. */
export function closerForUnclosedJsx(error: unknown): SegmentCloser | undefined {
  if (!(error instanceof Error) || (error as { ruleId?: unknown }).ruleId !== "end-tag-mismatch") return undefined;
  const name = /^Expected a closing tag for `<([^`>\s]*)/u.exec(error.message)?.[1];
  return name === undefined ? undefined : { kind: "jsx", name };
}

/** Offset of the line after the one that closes the construct, searching from `from` (a line
 * start), or undefined when nothing before the end of `text` closes it. */
export function closeOffset(text: string, from: number, closer: SegmentCloser): number | undefined {
  const pattern = closingPattern(closer);
  pattern.lastIndex = from;
  const match = pattern.exec(text);
  if (match === null) return undefined;
  const newline = text.indexOf("\n", match.index);
  return newline === -1 ? text.length : newline + 1;
}

function closingPattern(closer: SegmentCloser): RegExp {
  switch (closer.kind) {
    case "fence":
      return new RegExp(`^ {0,3}${escapeRegExp(closer.marker)}{${closer.size},}[ \\t]*$`, "gmu");
    case "html":
      return new RegExp(closer.end.source, `${closer.end.flags}g`);
    case "jsx":
      return new RegExp(`</${escapeRegExp(closer.name)}(?=[\\s/>]|$)`, "gmu");
  }
}

// CommonMark HTML blocks that continue across blank lines, by their opening line.
function htmlBlockEnd(line: string): RegExp | undefined {
  if (/^<(?:pre|script|style|textarea)(?:[\s>]|$)/iu.test(line)) return /<\/(?:pre|script|style|textarea)>/iu;
  if (line.startsWith("<!--")) return /-->/u;
  if (line.startsWith("<?")) return /\?>/u;
  if (line.startsWith("<![CDATA[")) return /\]\]>/u;
  if (/^<![A-Za-z]/u.test(line)) return />/u;
  return undefined;
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
}
