import type { PreviewFileKind } from "../src/bridge";
import { renderMarkdown, renderMdx } from "../src/pipeline";
import type { SegmentedRenderer, SegmentLimits } from "../src/segmented-render";

// `finest` tries every possible cut, so a test document of a few hundred bytes is cut
// wherever the rules allow.
export const finest: SegmentLimits = {
  minimumLength: 0,
  maximumLength: 0,
  cutHashModulus: 1,
  retryGrowth: 1,
};

export const coarse: SegmentLimits = {
  minimumLength: 40,
  maximumLength: 400,
  cutHashModulus: 3,
  retryGrowth: 2,
};

export async function whole(kind: PreviewFileKind, text: string): Promise<string> {
  return kind === "md" ? renderMarkdown(text) : renderMdx(text);
}

async function outcome(render: () => Promise<string>): Promise<string> {
  try {
    return await render();
  } catch (error) {
    return `THROWS ${(error as Error).message}`;
  }
}

/** Fails unless `renderer` returns (or throws) exactly what a whole render of `text` does.
 * Resolves to whether the document parses. */
export async function expectEquivalent(
  renderer: SegmentedRenderer,
  kind: PreviewFileKind,
  text: string,
  context: string,
): Promise<boolean> {
  const expected = await outcome(() => whole(kind, text));
  const actual = await outcome(() => renderer.render(text));
  if (actual !== expected) {
    throw new Error(`${context}\n--- document ---\n${JSON.stringify(text)}\n--- whole ---\n${expected}\n--- segmented ---\n${actual}`);
  }
  return !expected.startsWith("THROWS ");
}
