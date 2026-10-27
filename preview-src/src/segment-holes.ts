// Values in one segment's HTML that depend on the segments before it (agent.md §7.2,
// docs/decisions/2026-10-24-preview-segmented-render.md). In segment mode the pipeline
// writes a marker where such a value goes; assembly replaces each marker.
//
// micromark replaces U+0000 in its input with U+FFFD, so NUL can only come from these
// markers, and rehype-stringify escapes it as `&#x0;`. A document's own `&#x0;` text
// is decoded to U+FFFD, and any `&` it writes is escaped as `&amp;`.

/** Plugin option shared by the pipeline plugins that write markers. */
export interface SegmentHoleOptions {
  holes: boolean;
}

export type HoleKind =
  /** A source line (`data-line`, `data-line-end`), 1-based within the segment. */
  | "L"
  /** A `data-math-index`, 0-based within the segment. */
  | "M"
  /** The n-th generated heading ID within the segment. */
  | "H";

export function holeMarker(kind: HoleKind, value: number): string {
  return `\u0000${kind}${value}\u0000`;
}

/** Splits serialized HTML into `[text, kind, value, text, kind, value, …, text]`. */
export function splitHoles(html: string): string[] {
  return html.split(/&#x0;([LMH])(\d+)&#x0;/u);
}

/** Thrown in segment mode when only a whole-document render is exact. */
export class WholeDocumentRequired extends Error {
  constructor(reason: string) {
    super(`whole-document render required: ${reason}`);
  }
}

export interface WholeDocumentFileData extends Record<string, unknown> {
  /** Whole mode: the document has a construct that a segmented render cannot reproduce. */
  requiresWhole?: boolean;
}

/** A construct only a whole render reproduces: segment mode throws `WholeDocumentRequired`,
 * whole mode records it so the renderer keeps rendering whole while it is there. */
export function requireWholeDocument(
  file: { data: Record<string, unknown> },
  options: SegmentHoleOptions | undefined,
  reason: string,
): void {
  if (options?.holes) throw new WholeDocumentRequired(reason);
  (file.data as WholeDocumentFileData).requiresWhole = true;
}
