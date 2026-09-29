import type { ExportResourceDescriptor, ExportResourceKind, ExportResourceOutcome } from "./bridge";

// PreviewKit serializes every accepted resource in exactly this normalized form. Anything
// else fails closed; the base64 alphabet also needs no HTML attribute escaping, which the
// serialized-size budget relies on.
const strictImageDataURIPattern = /^data:image\/(?:png|jpeg|gif|webp);base64,[A-Za-z0-9+/]*={0,2}$/u;
const strictFontDataURIPattern = /^data:font\/woff2;base64,[A-Za-z0-9+/]*={0,2}$/u;

export function isStrictImageDataURI(value: string): boolean {
  return strictImageDataURIPattern.test(value);
}

export function isStrictFontDataURI(value: string): boolean {
  return strictFontDataURIPattern.test(value);
}

export interface ResolvedResourceOutcome {
  kind: ExportResourceKind;
  /** Set only for an `embed` outcome whose data URI passes the strict form check. */
  dataURI: string | null;
  reason: string | null;
  /** True when this outcome carried its own data URI (a valid `dataURIFrom` target). */
  ownsDataURI: boolean;
}

/**
 * Indexes the finalization outcomes once by resource ID. Outcomes for undiscovered IDs,
 * duplicated IDs, or a different resource kind are dropped, so their resources fail closed
 * to the omission placeholder. A protocol-v8 `dataURIFrom` reference must name an earlier
 * outcome of the same kind that carried its own data URI.
 */
export function resolveResourceOutcomes(
  descriptors: readonly ExportResourceDescriptor[],
  outcomes: readonly ExportResourceOutcome[],
): Map<string, ResolvedResourceOutcome> {
  const kinds = new Map(descriptors.map((descriptor) => [descriptor.resourceID, descriptor.kind]));
  const counts = new Map<string, number>();
  for (const outcome of outcomes) {
    counts.set(outcome.resourceID, (counts.get(outcome.resourceID) ?? 0) + 1);
  }
  const resolved = new Map<string, ResolvedResourceOutcome>();
  for (const outcome of outcomes) {
    if (counts.get(outcome.resourceID) !== 1 || kinds.get(outcome.resourceID) !== outcome.kind) continue;
    resolved.set(outcome.resourceID, resolveOutcome(outcome, resolved));
  }
  return resolved;
}

function resolveOutcome(
  outcome: ExportResourceOutcome,
  earlier: ReadonlyMap<string, ResolvedResourceOutcome>,
): ResolvedResourceOutcome {
  const reason = outcome.reason ?? null;
  const omitted: ResolvedResourceOutcome = { kind: outcome.kind, dataURI: null, reason, ownsDataURI: false };
  if (outcome.action !== "embed") return omitted;

  const reference = outcome.dataURIFrom ?? null;
  if (reference !== null) {
    const source = earlier.get(reference);
    if (outcome.dataURI != null || !source?.ownsDataURI || source.kind !== outcome.kind) return omitted;
    return { kind: outcome.kind, dataURI: source.dataURI, reason, ownsDataURI: false };
  }

  const dataURI = outcome.dataURI ?? "";
  const valid = outcome.kind === "image" ? isStrictImageDataURI(dataURI) : isStrictFontDataURI(dataURI);
  return valid ? { kind: outcome.kind, dataURI, reason, ownsDataURI: true } : omitted;
}
