export interface MdxErrorDetails {
  line?: number;
  message: string;
}

export function mdxErrorDetails(error: unknown): MdxErrorDetails {
  const candidate = error as {
    line?: unknown;
    reason?: unknown;
    message?: unknown;
    place?: unknown;
    position?: unknown;
  };
  const message =
    typeof candidate.reason === "string"
      ? candidate.reason
      : typeof candidate.message === "string"
        ? candidate.message
        : String(error);
  const line =
    numberFromUnknown(candidate.line) ??
    lineFromPlace(candidate.place) ??
    lineFromPlace(candidate.position) ??
    lineFromMessage(message);

  return { line, message };
}

export function mdxErrorBannerHtml(error: unknown): string {
  const details = mdxErrorDetails(error);
  const title =
    details.line === undefined ? "MDX syntax error" : `MDX syntax error on line ${details.line}`;

  return `<aside class="mdx-error-banner" role="status"><strong>${escapeHtml(
    title,
  )}</strong><span>${escapeHtml(details.message)}</span></aside>`;
}

function lineFromPlace(place: unknown): number | undefined {
  if (!place || typeof place !== "object") return undefined;
  const point = place as {
    line?: unknown;
    start?: { line?: unknown };
  };
  return numberFromUnknown(point.line) ?? numberFromUnknown(point.start?.line);
}

function numberFromUnknown(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function lineFromMessage(message: string): number | undefined {
  const match = message.match(/\((\d+):\d+(?:-\d+:\d+)?\)/u);
  if (!match) return undefined;

  const line = Number.parseInt(match[1], 10);
  return Number.isFinite(line) ? line : undefined;
}

function escapeHtml(value: string): string {
  return value.replace(/[&<>"']/gu, (character) => {
    switch (character) {
      case "&":
        return "&amp;";
      case "<":
        return "&lt;";
      case ">":
        return "&gt;";
      case '"':
        return "&quot;";
      case "'":
        return "&#x27;";
      default:
        return character;
    }
  });
}
