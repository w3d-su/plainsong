import remarkFrontmatter from "remark-frontmatter";
import type { Data, Processor } from "unified";

type MicromarkExtension = NonNullable<Data["micromarkExtensions"]>[number];

// micromark-extension-frontmatter's YAML fences: `---` at line 1, column 1 (micromark drops
// a BOM), then only spaces or tabs on the line. The opener needs a line ending; the first
// later fence line closes, also at the end of the document.
const opener = /^\uFEFF?---[ \t]*(?:\r\n|\r|\n)/;
const closer = /(?:^|[\r\n])---[ \t]*(?:[\r\n]|$)/;

/** Whether `remark-frontmatter` reads a YAML block at the start of `document`. */
export function hasClosedFrontmatter(document: string): boolean {
  return closedFrontmatterEnd(document) !== undefined;
}

/** Offset just after the closing fence line of the YAML block that `remark-frontmatter`
 * reads at the start of `document`, or undefined when there is none. */
export function closedFrontmatterEnd(document: string): number | undefined {
  const opening = opener.exec(document);
  if (opening === null) return undefined;
  const closing = closer.exec(document.slice(opening[0].length));
  return closing === null ? undefined : opening[0].length + closing.index + closing[0].length;
}

/**
 * `remark-frontmatter` for YAML, enabled per document only when its block closes.
 *
 * The extension's construct is `concrete`: while it looks for a closing fence, the document
 * tokenizer opens no containers. An unclosed opener fails only at the end of the document,
 * after every list and block quote in it was read as paragraph text. Gated off, the opener
 * is the thematic break CommonMark makes of it.
 */
export function remarkClosedFrontmatter(this: Processor) {
  remarkFrontmatter.call(this, ["yaml"]);
  const extensions = this.data().micromarkExtensions!;
  let closed = false;
  extensions.push(gated(extensions.pop()!, () => closed));

  // Parsing is synchronous, so the flag holds for exactly this document.
  const parse = this.parser!;
  this.parser = (document, file) => {
    closed = hasClosedFrontmatter(document);
    return parse(document, file);
  };
}

function gated(extension: MicromarkExtension, enabled: () => boolean): MicromarkExtension {
  const flow: NonNullable<MicromarkExtension["flow"]> = {};
  for (const [code, constructs] of Object.entries(extension.flow ?? {})) {
    flow[code] = [constructs ?? []].flat().map((construct) => ({
      ...construct,
      tokenize(effects, ok, nok) {
        return enabled() ? construct.tokenize.call(this, effects, ok, nok) : nok;
      },
    }));
  }
  return { ...extension, flow };
}
