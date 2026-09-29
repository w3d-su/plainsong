import type { ExportResourceDescriptor } from "./bridge";
import {
  EXPORT_IMAGE_SIZE_LIMIT_REASON,
  placeholderElement,
  placeholderLabel,
  sanitizeStaticClone,
  utf8ByteLength,
} from "./export-html-assets";
import { isStrictImageDataURI, type ResolvedResourceOutcome } from "./export-html-outcomes";

/** Resolves true only after the data URI fully decodes in this WebContent process. */
export type ExportImageDecoder = (dataURI: string) => Promise<boolean>;

export interface ExportImageSlot {
  /** The placeholder currently standing in for the image in the static clone. */
  placeholder: HTMLSpanElement;
  /** A detached, sanitized image carrying its Swift-accepted data URI, or null. */
  candidate: HTMLImageElement | null;
  dataURI: string | null;
  decoded: boolean;
  /** Label used if the candidate is rejected for any reason other than size. */
  fallbackLabel: string;
}

export interface SerializedImageBudget {
  status: "ok" | "base-too-large";
  byteLength: number;
}

export function exportImageSource(image: HTMLImageElement): string {
  return image.getAttribute("src") ??
    image.dataset.plainsongBlockedSrc ??
    image.dataset.plainsongOriginalSrc ??
    "";
}

export function collectImageResources(root: ParentNode): ExportResourceDescriptor[] {
  return Array.from(root.querySelectorAll("img")).map((image, index) => ({
    resourceID: `image-${index}`,
    kind: "image" as const,
    src: exportImageSource(image),
  }));
}

/** Outcomes pair with images by index, so the DOM must still be the one discovery described. */
export function matchesDiscoveredImages(
  images: readonly HTMLImageElement[],
  descriptors: readonly ExportResourceDescriptor[],
): boolean {
  const discovered = descriptors.filter((descriptor) => descriptor.kind === "image");
  return discovered.length === images.length && discovered.every((descriptor, index) => (
    descriptor.resourceID === `image-${index}` && descriptor.src === exportImageSource(images[index])
  ));
}

/**
 * Replaces every image in the clone with a placeholder. Only an image whose own outcome
 * is a Swift-accepted embed becomes a candidate; an image with no valid outcome fails
 * closed. A candidate's placeholder already carries the size-limit label, so the base
 * measurement is exactly the document the budget produces when it rejects the image.
 */
export function detachExportImages(
  images: readonly HTMLImageElement[],
  outcomes: ReadonlyMap<string, ResolvedResourceOutcome>,
  allowedFontDataURIs: ReadonlySet<string>,
): ExportImageSlot[] {
  return images.map((image, index) => {
    const outcome = outcomes.get(`image-${index}`);
    const dataURI = outcome?.kind === "image" ? outcome.dataURI : null;
    const fallbackLabel = placeholderLabel(image, null);
    const placeholder = placeholderElement(
      image,
      dataURI ? EXPORT_IMAGE_SIZE_LIMIT_REASON : placeholderLabel(image, outcome?.reason),
    );
    image.replaceWith(placeholder);
    const slot: ExportImageSlot = { placeholder, candidate: null, dataURI: null, decoded: false, fallbackLabel };
    if (dataURI && sanitizeCandidate(image, dataURI, allowedFontDataURIs)) {
      slot.candidate = image;
      slot.dataURI = dataURI;
    } else if (dataURI) {
      replacePlaceholder(slot, fallbackLabel);
    }
    return slot;
  });
}

/**
 * D3 decode barrier: each distinct candidate data URI is decoded once. A candidate that
 * does not decode becomes its inert alt placeholder and export continues.
 */
export async function decodeImageCandidates(
  slots: readonly ExportImageSlot[],
  decode: ExportImageDecoder,
): Promise<void> {
  const results = new Map<string, Promise<boolean>>();
  await Promise.all(slots.map(async (slot) => {
    if (!slot.candidate || !slot.dataURI) return;
    let result = results.get(slot.dataURI);
    if (!result) {
      const dataURI = slot.dataURI;
      result = Promise.resolve().then(() => decode(dataURI)).catch(() => false);
      results.set(dataURI, result);
    }
    if ((await result) === true) {
      slot.decoded = true;
      return;
    }
    slot.candidate = null;
    slot.dataURI = null;
    replacePlaceholder(slot, slot.fallbackLabel);
  }));
}

/**
 * Measures the sanitized clone with every optional image as a placeholder, then admits
 * decoded candidates in stable document order while the final document stays within
 * `limit`. Nothing mutates the clone afterwards, so `byteLength` is the final HTML size.
 */
export function applySerializedImageBudget(options: {
  clone: HTMLElement;
  slots: readonly ExportImageSlot[];
  measure: (bodyHTML: string) => number | null;
  limit: number;
}): SerializedImageBudget {
  const baseLength = options.measure(options.clone.innerHTML);
  if (baseLength === null || baseLength > options.limit) {
    return { status: "base-too-large", byteLength: baseLength ?? Number.POSITIVE_INFINITY };
  }

  let used = baseLength;
  for (const slot of options.slots) {
    if (!slot.candidate || !slot.dataURI || !slot.decoded) continue;
    // Sanitization may have dropped the placeholder's container (e.g. a user SVG).
    if (!options.clone.contains(slot.placeholder)) continue;
    const delta = serializedImageLength(slot.candidate, slot.dataURI) - utf8ByteLength(slot.placeholder.outerHTML);
    if (used + delta > options.limit) continue;
    slot.placeholder.replaceWith(slot.candidate);
    used += delta;
  }
  return { status: "ok", byteLength: used };
}

/** The ready barrier: every image left in the static clone is a decoded candidate. */
export function everyRetainedImageDecoded(root: ParentNode, slots: readonly ExportImageSlot[]): boolean {
  const decoded = new Set(slots.flatMap((slot) => (slot.decoded && slot.candidate ? [slot.candidate] : [])));
  return Array.from(root.querySelectorAll("img")).every((image) => decoded.has(image));
}

function sanitizeCandidate(
  image: HTMLImageElement,
  dataURI: string,
  allowedFontDataURIs: ReadonlySet<string>,
): boolean {
  if (!isStrictImageDataURI(dataURI)) return false;
  image.setAttribute("src", dataURI);
  const holder = image.ownerDocument.createElement("div");
  holder.append(image);
  sanitizeStaticClone(holder, allowedFontDataURIs);
  const kept = holder.childNodes.length === 1 && holder.firstChild === image &&
    image.getAttribute("src") === dataURI;
  image.remove();
  return kept;
}

function replacePlaceholder(slot: ExportImageSlot, label: string): void {
  const next = placeholderElement(slot.placeholder, label);
  slot.placeholder.replaceWith(next);
  slot.placeholder = next;
}

function serializedImageLength(image: HTMLImageElement, dataURI: string): number {
  // A strict data URI needs no attribute escaping, so measure without copying its bytes.
  image.setAttribute("src", "");
  const length = utf8ByteLength(image.outerHTML) + dataURI.length;
  image.setAttribute("src", dataURI);
  return length;
}
