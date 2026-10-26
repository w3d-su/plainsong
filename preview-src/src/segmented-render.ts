import type { PreviewFileKind } from "./bridge";
import { closedFrontmatterEnd } from "./frontmatter";
import { HeadingSlugAllocator, headingIDPrefix } from "./heading-anchors";
import {
  type RenderedSegment,
  renderSegment,
  renderWholeDocument,
  SegmentBoundaryOpen,
} from "./pipeline";
import { closeOffset, closerForUnclosedJsx, type SegmentCloser } from "./segment-closers";
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
// sentinel does not come back as a paragraph of its own and the cut is not taken. The
// next try skips to where that construct closes, and is at least `retryGrowth` times as
// long, so the tries from one start cost about as much as the segment they end with.

export interface SegmentLimits {
  /** Smallest segment that may end at a content-chosen cut. */
  minimumLength: number;
  /** A segment this long ends at the next acceptable cut regardless of content. */
  maximumLength: number;
  /** A content-chosen cut is a line whose hash is divisible by this. */
  cutHashModulus: number;
  /** After an open cut, the next try from the same start needs a segment at least this many
   * times as long. */
  retryGrowth: number;
}

// About 2-4 KB per segment: one segment re-renders in a few milliseconds, and a 1 MiB
// document has a few hundred, so per-segment overhead stays small.
const defaultLimits: SegmentLimits = {
  minimumLength: 2_048,
  maximumLength: 16_384,
  cutHashModulus: 4,
  retryGrowth: 2,
};

/** What rendering one segment showed. */
type SegmentOutcome =
  | { kind: "rendered"; segment: RenderedSegment }
  /** A construct continues past the cut; `closer` says how it ends, when that is known. */
  | { kind: "open"; closer?: SegmentCloser }
  /** The segment does not parse. `esm`: the error is in ESM, which parses differently after
   * the imports of earlier segments. */
  | { kind: "error"; esm: boolean }
  /** Only a whole-document render is exact (a definition, an unplaced KaTeX message). */
  | { kind: "whole" };

/** Outcomes by segment text. A segment followed by another is parsed with the sentinel on the
 * line after its text, so the text alone fixes its outcome; a last segment is parsed without
 * one and is kept apart. */
class SegmentCache {
  readonly inner = new Map<string, SegmentOutcome>();
  readonly last = new Map<string, SegmentOutcome>();
}

export class SegmentedRenderer {
  private previous = new SegmentCache();
  private current = new SegmentCache();
  /** The last render did not parse ("failed") or had a construct only a whole render
   * reproduces ("required"). Renders stay whole, without a segment pass, until a whole render
   * shows neither. */
  private wholeNext: "failed" | "required" | undefined;
  /** The definition-like lines (`definitionCandidates`) the last whole render saw. */
  private checkedCandidates = "";
  /** The definition-like lines of the text whose whole render was "required". */
  private requiredCandidates = "";
  /** Segments the last `render` call ran through the pipeline (cache misses). */
  renderedSegmentCount = 0;
  /** Segments the last `render` call assembled, or 0 after a whole-document render. */
  assembledSegmentCount = 0;

  constructor(
    readonly fileKind: PreviewFileKind,
    private readonly limits: SegmentLimits = defaultLimits,
  ) {}

  /** Equal to `renderMarkdown(text)` (or `renderMdx`), including what it throws. */
  async render(text: string): Promise<string> {
    this.renderedSegmentCount = 0;
    this.assembledSegmentCount = 0;
    // A definition makes the document render whole. New definition-like lines go to a whole
    // render first, which says whether one is real, instead of to a segment pass that would
    // find it only at its segment.
    const candidates = definitionCandidates(text);
    const startWhole =
      this.wholeNext === "failed" ||
      // Once the lines that showed the definitions are gone (another document, or deleted),
      // segment again; a verdict those lines did not show stays until a whole render clears it.
      (this.wholeNext === "required" && (candidates !== "" || this.requiredCandidates === "")) ||
      (candidates !== "" && candidates !== this.checkedCandidates);
    if (startWhole) {
      this.checkedCandidates = candidates;
      return this.renderWhole(text, candidates);
    }

    let segments: PlacedSegment[] | undefined;
    try {
      segments = this.segments(text);
    } finally {
      this.previous = this.current;
      this.current = new SegmentCache();
    }
    if (segments === undefined) return this.renderWhole(text, candidates);
    this.wholeNext = undefined;
    this.assembledSegmentCount = segments.length;
    return assemble(segments);
  }

  /** The whole render, which also decides whether the next render may segment. It leaves the
   * segment cache alone, so segmenting resumes with the segments of the last segmented render. */
  private async renderWhole(text: string, candidates: string): Promise<string> {
    // Stays set when the render throws: a document that does not parse renders whole until
    // it does, instead of parsing as segments and then again as a whole for its error.
    this.wholeNext = "failed";
    const { html, requiresWhole } = await renderWholeDocument(this.fileKind, text);
    this.wholeNext = requiresWhole ? "required" : undefined;
    this.requiredCandidates = candidates;
    return html;
  }

  /** Segments of `text` in order, or undefined when the whole text is one segment or only a
   * whole-document render is exact. */
  private segments(text: string): PlacedSegment[] | undefined {
    // micromark counts a lone CR as a line ending; the scanner below counts LF only.
    if (/\r(?!\n)/u.test(text)) return undefined;
    // A cut inside frontmatter would split it. The first segment holds the closing fence,
    // so remarkClosedFrontmatter reads it there as it does in the whole document; later
    // segments never start with `-` or a BOM, so it reads none in them.
    const frontmatterEnd = closedFrontmatterEnd(text) ?? 0;

    const { minimumLength, maximumLength, cutHashModulus, retryGrowth } = this.limits;
    const segments: PlacedSegment[] = [];
    let start = 0;
    let startLine = 1;
    // After an open cut, the next try from `start` waits for a cut at this offset.
    let retryFrom = 0;
    // The first placed segment whose ESM imports a binding.
    let importer: number | undefined;

    // Places text[start, end), ending before document line `endLine` (none for the last).
    const place = (outcome: SegmentOutcome, end: number, endLine: number | undefined): boolean => {
      // micromark-extension-mdxjs-esm parses each ESM block after `var <imports of earlier
      // blocks>`, so ESM parses differently after the imports of an earlier segment. Such a
      // segment is merged with every segment from the importing one, which then parses with
      // the same imports as in the whole document.
      const esm = (outcome.kind === "rendered" && outcome.segment.hasEsm) ||
        (outcome.kind === "error" && outcome.esm);
      if (importer !== undefined && esm) {
        const from = segments[importer];
        const merged = this.outcome(
          text.slice(from.offset, end),
          endLine === undefined ? undefined : endLine - from.startLine + 1,
        );
        if (merged.kind !== "rendered") return false;
        segments.length = importer;
        segments.push({ segment: merged.segment, startLine: from.startLine, offset: from.offset });
        return true;
      }
      if (outcome.kind !== "rendered") return false;
      if (importer === undefined && outcome.segment.importsBindings) importer = segments.length;
      segments.push({ segment: outcome.segment, startLine, offset: start });
      return true;
    };

    for (const cut of cuts(text, frontmatterEnd)) {
      if (cut.offset < retryFrom) continue;
      const length = cut.offset - start;
      if (length < minimumLength) continue;
      if (length < maximumLength && cut.hash % cutHashModulus !== 0) continue;

      const outcome = this.outcome(text.slice(start, cut.offset), cut.line - startLine + 1);
      if (outcome.kind === "open") {
        const retry = nextTry(text, start, cut.offset, outcome.closer, retryGrowth);
        if (retry === "whole") return undefined;
        if (retry === undefined) break;
        retryFrom = retry;
        continue;
      }
      if (!place(outcome, cut.offset, cut.line)) return undefined;
      start = cut.offset;
      startLine = cut.line;
      retryFrom = 0;
    }
    if (segments.length === 0) return undefined;

    // The last segment's errors are the document's: a whole render reports them.
    if (!place(this.outcome(text.slice(start), undefined), text.length, undefined)) return undefined;
    return segments;
  }

  private outcome(text: string, nextSegmentLine: number | undefined): SegmentOutcome {
    const cache = nextSegmentLine === undefined ? "last" : "inner";
    let outcome = this.current[cache].get(text) ?? this.previous[cache].get(text);
    if (outcome === undefined) {
      this.renderedSegmentCount += 1;
      outcome = renderOutcome(this.fileKind, text, nextSegmentLine);
    }
    this.current[cache].set(text, outcome);
    return outcome;
  }
}

function renderOutcome(
  fileKind: PreviewFileKind,
  text: string,
  nextSegmentLine: number | undefined,
): SegmentOutcome {
  try {
    return { kind: "rendered", segment: renderSegment(fileKind, text, nextSegmentLine) };
  } catch (error) {
    if (error instanceof WholeDocumentRequired) return { kind: "whole" };
    if (error instanceof SegmentBoundaryOpen) return { kind: "open", closer: error.closer };
    // An MDX error placed at the sentinel's line or later, or with no place, comes from
    // reaching the end of the text: the construct may close in a later segment. One placed
    // before it is in the segment itself.
    const line = (error as { line?: unknown }).line;
    if (nextSegmentLine !== undefined && (typeof line !== "number" || line >= nextSegmentLine)) {
      return { kind: "open", closer: closerForUnclosedJsx(error) };
    }
    return { kind: "error", esm: (error as { source?: unknown }).source === "micromark-extension-mdxjs-esm" };
  }
}

/**
 * Where the next try from `start` may cut after the cut at `cutOffset` came back open: past
 * the line that closes the open construct and `growth` times as long as the open segment.
 * Undefined: no later cut from `start` is worth a try, and the rest is the last segment.
 * "whole": the MDX element never closes, so the document does not parse.
 */
function nextTry(
  text: string,
  start: number,
  cutOffset: number,
  closer: SegmentCloser | undefined,
  growth: number,
): number | "whole" | undefined {
  const grown = start + (cutOffset - start) * growth;
  if (closer === undefined) {
    // Unknown end: stop before a try would hold more than half of the rest, which keeps the
    // tries to about the length of the rest when the construct never closes.
    return grown - start > (text.length - start) / 2 ? undefined : grown;
  }
  const close = closeOffset(text, cutOffset, closer);
  if (close === undefined) return closer.kind === "jsx" ? "whole" : undefined;
  return Math.max(grown, close);
}

interface PlacedSegment {
  segment: RenderedSegment;
  startLine: number;
  /** UTF-16 offset of the segment's first character. */
  offset: number;
}

function assemble(segments: PlacedSegment[]): string {
  const output: string[] = [];
  const slugs = new HeadingSlugAllocator();
  let mathOffset = 0;
  let joined = false;
  for (const { segment, startLine } of segments) {
    const ids = segment.headingSlugs.map((base) => headingIDPrefix + slugs.next(base));
    const { pieces } = segment;
    // The root's nodes are joined by newlines before the MDX pipeline drops any, so a segment
    // joins when it had nodes, even if none reached its HTML.
    if (segment.hasBlocks) {
      if (joined) output.push("\n");
      joined = true;
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

// A line that may start a link reference or footnote definition: `[label]:` after
// indentation, block quote markers and a list marker.
const definitionLine = /^[ \t]*(?:>[ \t]*)*(?:(?:[-+*]|\d{1,9}[.)])[ \t]+)?\[[^\]\n]*\]:/gmu;

/** The definition-like lines of `text`, joined. Every definition has `]:` after its label; one
 * whose label spans lines is missed here, which costs a segment pass before its whole render. */
function definitionCandidates(text: string): string {
  if (!text.includes("]:")) return "";
  return text.match(definitionLine)?.join("\n") ?? "";
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
