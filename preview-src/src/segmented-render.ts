import type { PreviewFileKind } from "./bridge";
import { HeadingSlugAllocator, headingIDPrefix } from "./heading-anchors";
import {
  type RenderedSegment,
  renderMarkdown,
  renderMdx,
  renderSegment,
  SegmentBoundaryOpen,
} from "./pipeline";
import { WholeDocumentRequired } from "./segment-holes";

// Incremental preview rendering (docs/decisions/2026-10-24-preview-segmented-render.md).
// The document is cut into segments at block boundaries, each segment renders on its own,
// and segments whose text did not change reuse their HTML from the previous render. The
// result is the same string `renderMarkdown`/`renderMdx` returns for the whole text.
//
// A cut goes before a line that follows a blank line, starts in column 1, and cannot
// continue a list (no `-`, `+`, `*` or `1.`/`1)`), open frontmatter, or carry a BOM.
// The segment before the cut is parsed with a sentinel paragraph where the next one
// starts: if a construct is still open there (a fence, math, an HTML block, MDX), the
// sentinel does not come back as a paragraph of its own and the cut is not taken.

export interface SegmentLimits {
  /** Smallest segment that may end at a content-chosen cut. */
  minimumLength: number;
  /** A segment this long ends at the next acceptable cut regardless of content. */
  maximumLength: number;
  /** A content-chosen cut is a line whose hash is divisible by this. */
  cutHashModulus: number;
  /** Open cuts tried from one segment start before the rest becomes one segment. */
  maximumRejectedCuts: number;
}

// About 2-4 KB per segment: one segment re-renders in a few milliseconds, and a 1 MiB
// document has a few hundred, so per-segment overhead stays small.
const defaultLimits: SegmentLimits = {
  minimumLength: 2_048,
  maximumLength: 16_384,
  cutHashModulus: 4,
  maximumRejectedCuts: 4,
};

/** "open": a construct continues past the cut. "whole": the document needs a whole render. */
type SegmentOutcome = RenderedSegment | "open" | "whole";

export class SegmentedRenderer {
  private previous = new Map<string, SegmentOutcome>();
  private current = new Map<string, SegmentOutcome>();
  /** Segments the last `render` call ran through the pipeline (cache misses). */
  renderedSegmentCount = 0;
  /** Segments the last `render` call assembled, or 0 after a whole-document render. */
  assembledSegmentCount = 0;

  constructor(
    private readonly fileKind: PreviewFileKind,
    private readonly limits: SegmentLimits = defaultLimits,
  ) {}

  /** Equal to `renderMarkdown(text)` (or `renderMdx`), including what it throws. */
  async render(text: string): Promise<string> {
    let segments: PlacedSegment[] | undefined;
    this.renderedSegmentCount = 0;
    try {
      segments = this.segments(text);
    } finally {
      this.previous = this.current;
      this.current = new Map();
    }
    this.assembledSegmentCount = segments?.length ?? 0;
    if (segments !== undefined) return assemble(segments);
    return this.fileKind === "md" ? renderMarkdown(text) : renderMdx(text);
  }

  /** Segments of `text` in order, or undefined when the whole text is one segment or a
   * segment fails in a way only a whole-document render reproduces. */
  private segments(text: string): PlacedSegment[] | undefined {
    // micromark counts a lone CR as a line ending; the scanner below counts LF only.
    if (/\r(?!\n)/u.test(text)) return undefined;
    const frontmatterEnd = frontmatterEndOffset(text);
    if (frontmatterEnd === undefined) return undefined;

    const { minimumLength, maximumLength, cutHashModulus, maximumRejectedCuts } = this.limits;
    const segments: PlacedSegment[] = [];
    let start = 0;
    let startLine = 1;
    let rejected = 0;
    let importsSeen = false;
    // Whether an ESM block parses depends on the bindings earlier blocks import.
    const place = (segment: RenderedSegment, line: number): boolean => {
      if (importsSeen && segment.hasEsm) return false;
      importsSeen ||= segment.importsBindings;
      segments.push({ segment, startLine: line });
      return true;
    };
    for (const cut of cuts(text, frontmatterEnd)) {
      const length = cut.offset - start;
      if (length < minimumLength) continue;
      if (length < maximumLength && cut.hash % cutHashModulus !== 0) continue;

      const outcome = this.outcome(text.slice(start, cut.offset), cut.line - startLine + 1);
      if (outcome === "whole") return undefined;
      if (outcome === "open") {
        rejected += 1;
        if (rejected > maximumRejectedCuts) break;
        continue;
      }
      if (!place(outcome, startLine)) return undefined;
      start = cut.offset;
      startLine = cut.line;
      rejected = 0;
    }
    if (segments.length === 0) return undefined;

    // The last segment's errors are the document's: let the whole render report them.
    let last: SegmentOutcome;
    try {
      last = this.outcome(text.slice(start), undefined);
    } catch {
      return undefined;
    }
    if (typeof last === "string" || !place(last, startLine)) return undefined;
    return segments;
  }

  private outcome(text: string, nextSegmentLine: number | undefined): SegmentOutcome {
    const key = `${nextSegmentLine === undefined ? "end" : nextSegmentLine}\n${text}`;
    let outcome = this.current.get(key) ?? this.previous.get(key);
    if (outcome === undefined) {
      this.renderedSegmentCount += 1;
      try {
        outcome = renderSegment(this.fileKind, text, nextSegmentLine);
      } catch (error) {
        if (error instanceof WholeDocumentRequired) {
          outcome = "whole";
        } else if (error instanceof SegmentBoundaryOpen || nextSegmentLine !== undefined) {
          // A parse error before the last cut can come from cutting a construct in two.
          outcome = "open";
        } else {
          throw error;
        }
      }
    }
    this.current.set(key, outcome);
    return outcome;
  }
}

interface PlacedSegment {
  segment: RenderedSegment;
  startLine: number;
}

function assemble(segments: PlacedSegment[]): string {
  const output: string[] = [];
  const slugs = new HeadingSlugAllocator();
  let mathOffset = 0;
  for (const { segment, startLine } of segments) {
    const ids = segment.headingSlugs.map((base) => headingIDPrefix + slugs.next(base));
    const { pieces } = segment;
    // The root's blocks are joined by newlines; an empty segment adds none.
    if (pieces.length > 1 || pieces[0] !== "") {
      if (output.length > 0) output.push("\n");
      output.push(pieces[0]);
      for (let index = 1; index < pieces.length; index += 3) {
        const value = Number(pieces[index + 1]);
        switch (pieces[index]) {
          case "L":
            output.push(String(value + startLine - 1));
            break;
          case "M":
            output.push(String(value + mathOffset));
            break;
          default:
            output.push(ids[value]);
        }
        output.push(pieces[index + 2]);
      }
    }
    mathOffset += segment.mathCount;
  }
  return output.join("");
}

interface Cut {
  /** UTF-16 offset of the first character of the line the next segment starts with. */
  offset: number;
  /** 1-based line number of that line. */
  line: number;
  hash: number;
}

/** Cuts after `firstOffset`, in order. */
function* cuts(text: string, firstOffset: number): Generator<Cut> {
  let lineStart = 0;
  let line = 1;
  let previousBlank = false;
  while (lineStart < text.length) {
    const newline = text.indexOf("\n", lineStart);
    const lineEnd = newline === -1 ? text.length : newline;
    if (previousBlank && lineStart >= firstOffset && startsSegment(text, lineStart)) {
      yield { offset: lineStart, line, hash: lineHash(text, lineStart, lineEnd) };
    }
    previousBlank = isBlank(text, lineStart, lineEnd);
    if (newline === -1) break;
    lineStart = newline + 1;
    line += 1;
  }
}

/**
 * Where YAML frontmatter ends (0 without frontmatter); cuts inside it would split it.
 * Undefined for an opening fence that never closes: micromark-extension-frontmatter then
 * leaves the parser unable to open lists and block quotes anywhere in the document, which
 * only a whole render reproduces. Fences are `---` plus optional spaces or tabs, alone on
 * a line. micromark skips one leading BOM before it looks for the opening fence.
 */
function frontmatterEndOffset(text: string): number | undefined {
  if (!/^\uFEFF?---[ \t]*\r?\n/u.test(text)) return 0;
  const closingFence = /\n---[ \t]*\r?(?:\n|$)/gu;
  closingFence.lastIndex = 3;
  return closingFence.exec(text) === null ? undefined : closingFence.lastIndex;
}

function isBlank(text: string, start: number, end: number): boolean {
  for (let index = start; index < end; index += 1) {
    const code = text.charCodeAt(index);
    // Space, tab, and the CR of a CRLF line ending.
    if (code !== 0x20 && code !== 0x09 && code !== 0x0d) return false;
  }
  return true;
}

function startsSegment(text: string, start: number): boolean {
  const code = text.charCodeAt(start);
  switch (code) {
    case 0x20: // space: indented code, list continuation
    case 0x09: // tab
    case 0x0a: // blank line
    case 0x0d:
    case 0x2a: // `*` bullet or thematic break
    case 0x2b: // `+` bullet
    case 0x2d: // `-` bullet, thematic break, frontmatter fence
    case 0xfeff: // byte order mark, stripped only at the start of a document
      return false;
  }
  // An ordered list marker: up to nine digits, then `.` or `)`.
  let index = start;
  while (index < text.length && index - start < 9) {
    const digit = text.charCodeAt(index);
    if (digit < 0x30 || digit > 0x39) break;
    index += 1;
  }
  if (index === start) return true;
  const marker = text.charCodeAt(index);
  return marker !== 0x2e && marker !== 0x29;
}

/** FNV-1a over the first 64 UTF-16 units: cuts depend on nearby text only, so an edit
 * moves at most the cuts around it. */
function lineHash(text: string, start: number, end: number): number {
  let hash = 0x811c9dc5;
  const limit = Math.min(end, start + 64);
  for (let index = start; index < limit; index += 1) {
    hash ^= text.charCodeAt(index);
    hash = Math.imul(hash, 0x01000193);
  }
  return hash >>> 0;
}
