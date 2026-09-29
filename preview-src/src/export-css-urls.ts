// D3 CSS URL sinks for static export. A regular expression cannot see CSS escapes
// (`u\72l(`, `@\69mport`), quotes or `)` inside url values, or string URL sinks such as
// `@import "…"` and `image-set("…")`. This small CSS Syntax Level 3 scanner decodes
// escaped names, reads quoted and unquoted url() values, and fails closed: an
// unterminated or malformed url() never survives, `@import` rules are dropped, and other
// URL-bearing functions become `none`.

import { isStrictFontDataURI } from "./export-html-outcomes";

/**
 * Receives the decoded URL (`null` when the construct is malformed or unterminated) and
 * the exact source text of the whole `url(...)` construct; returns its replacement.
 */
export type CSSURLRewriter = (value: string | null, raw: string) => string;

const urlBearingFunctions = new Set([
  "image-set",
  "-webkit-image-set",
  "image",
  "-webkit-image",
  "cross-fade",
  "-webkit-cross-fade",
  "element",
  "-moz-element",
  "src",
]);

const fragmentPattern = /^#[A-Za-z0-9_.:-]+$/u;

export function rewriteCSSURLs(css: string, rewrite: CSSURLRewriter): string {
  let output = "";
  let index = 0;
  while (index < css.length) {
    const character = css[index];
    if (character === "/" && css[index + 1] === "*") {
      const close = css.indexOf("*/", index + 2);
      const end = close === -1 ? css.length : close + 2;
      output += css.slice(index, end);
      index = end;
    } else if (character === '"' || character === "'") {
      const end = consumeString(css, index).end;
      output += css.slice(index, end);
      index = end;
    } else if (character === "@") {
      const name = consumeName(css, index + 1);
      if (name?.value.toLowerCase() === "import") {
        index = skipAtRule(css, name.end);
      } else {
        output += character;
        index += 1;
      }
    } else if (startsName(css, index)) {
      const name = consumeName(css, index) ?? { value: "", end: index + 1 };
      const functionName = css[name.end] === "(" ? name.value.toLowerCase() : "";
      if (functionName === "url") {
        const url = consumeURL(css, name.end + 1);
        output += rewrite(url.value, css.slice(index, url.end));
        index = url.end;
      } else if (urlBearingFunctions.has(functionName)) {
        output += "none";
        index = skipBlock(css, name.end + 1);
      } else {
        output += css.slice(index, name.end);
        index = name.end;
      }
    } else {
      output += character;
      index += 1;
    }
  }
  return output;
}

/** Keeps only same-document fragments and Swift-embedded manifest font data. */
export function sanitizeCSSURLs(css: string, allowedFontDataURIs: ReadonlySet<string>): string {
  return rewriteCSSURLs(css, (value) => (
    value !== null && isAllowedCSSURL(value, allowedFontDataURIs) ? `url("${value}")` : "url()"
  ));
}

export function isAllowedCSSURL(value: string, allowedFontDataURIs: ReadonlySet<string>): boolean {
  if (fragmentPattern.test(value)) return true;
  return allowedFontDataURIs.has(value) && isStrictFontDataURI(value);
}

interface Consumed {
  value: string;
  end: number;
}

function isNameCodePoint(character: string | undefined): boolean {
  if (character === undefined) return false;
  return /[A-Za-z0-9_-]/u.test(character) || character.charCodeAt(0) >= 0x80;
}

function isNewline(character: string | undefined): boolean {
  return character === "\n" || character === "\r" || character === "\f";
}

function isWhitespace(character: string | undefined): boolean {
  return character === " " || character === "\t" || isNewline(character);
}

function isValidEscape(css: string, index: number): boolean {
  return css[index] === "\\" && !isNewline(css[index + 1]);
}

function startsName(css: string, index: number): boolean {
  return isNameCodePoint(css[index]) || isValidEscape(css, index);
}

function consumeName(css: string, start: number): Consumed | null {
  let value = "";
  let index = start;
  while (index < css.length) {
    if (isNameCodePoint(css[index])) {
      value += css[index];
      index += 1;
    } else if (isValidEscape(css, index)) {
      const escape = consumeEscape(css, index + 1);
      value += escape.value;
      index = escape.end;
    } else {
      break;
    }
  }
  return index === start ? null : { value, end: index };
}

function consumeEscape(css: string, start: number): Consumed {
  if (start >= css.length) return { value: "�", end: start };
  let index = start;
  let hex = "";
  while (hex.length < 6 && /[0-9A-Fa-f]/u.test(css[index] ?? "")) {
    hex += css[index];
    index += 1;
  }
  if (!hex) {
    const codePoint = css.codePointAt(start) ?? 0xfffd;
    return { value: String.fromCodePoint(codePoint), end: start + (codePoint > 0xffff ? 2 : 1) };
  }
  if (css[index] === "\r" && css[index + 1] === "\n") index += 2;
  else if (isWhitespace(css[index])) index += 1;
  const codePoint = Number.parseInt(hex, 16);
  const valid = codePoint > 0 && codePoint <= 0x10ffff && (codePoint < 0xd800 || codePoint > 0xdfff);
  return { value: valid ? String.fromCodePoint(codePoint) : "�", end: index };
}

function consumeString(css: string, start: number): Consumed & { terminated: boolean } {
  const quote = css[start];
  let value = "";
  let index = start + 1;
  while (index < css.length) {
    const character = css[index];
    if (character === quote) return { value, end: index + 1, terminated: true };
    if (isNewline(character)) return { value, end: index, terminated: false };
    if (character === "\\") {
      if (index + 1 >= css.length) {
        index += 1;
      } else if (isNewline(css[index + 1])) {
        index += css[index + 1] === "\r" && css[index + 2] === "\n" ? 3 : 2;
      } else {
        const escape = consumeEscape(css, index + 1);
        value += escape.value;
        index = escape.end;
      }
      continue;
    }
    value += character;
    index += 1;
  }
  return { value, end: index, terminated: false };
}

function skipWhitespace(css: string, start: number): number {
  let index = start;
  while (isWhitespace(css[index])) index += 1;
  return index;
}

function consumeURL(css: string, start: number): { value: string | null; end: number } {
  let index = skipWhitespace(css, start);
  if (css[index] === '"' || css[index] === "'") {
    const string = consumeString(css, index);
    index = skipWhitespace(css, string.end);
    if (string.terminated && css[index] === ")") return { value: string.value, end: index + 1 };
    return { value: null, end: skipBlock(css, index) };
  }
  let value = "";
  while (index < css.length) {
    const character = css[index];
    if (character === ")") return { value, end: index + 1 };
    if (isWhitespace(character)) {
      const next = skipWhitespace(css, index);
      if (css[next] === ")") return { value, end: next + 1 };
      return { value: null, end: skipBadURL(css, next) };
    }
    if (character === '"' || character === "'" || character === "(" || isNonPrintable(character)) {
      return { value: null, end: skipBadURL(css, index) };
    }
    if (character === "\\") {
      if (!isValidEscape(css, index)) return { value: null, end: skipBadURL(css, index) };
      const escape = consumeEscape(css, index + 1);
      value += escape.value;
      index = escape.end;
      continue;
    }
    value += character;
    index += 1;
  }
  return { value: null, end: css.length };
}

function isNonPrintable(character: string): boolean {
  const code = character.charCodeAt(0);
  return code <= 0x08 || code === 0x0b || (code >= 0x0e && code <= 0x1f) || code === 0x7f;
}

function skipBadURL(css: string, start: number): number {
  let index = start;
  while (index < css.length) {
    if (css[index] === ")") return index + 1;
    // Keep the enclosing block's `}` so later rules survive; the rest is still scanned.
    if (css[index] === "}") return index;
    index = isValidEscape(css, index) ? consumeEscape(css, index + 1).end : index + 1;
  }
  return css.length;
}

/**
 * Skips to just past the `)` that closes an already-open function, or to the end. An
 * unmatched `}` or `]` stops the skip before it, so the enclosing block and later rules
 * survive; everything after the stop is still scanned.
 */
function skipBlock(css: string, start: number): number {
  let depth = 1;
  let index = start;
  while (index < css.length) {
    const next = skipAtomic(css, index);
    if (next !== index) {
      index = next;
      continue;
    }
    const character = css[index];
    if (depth === 1 && (character === "}" || character === "]")) return index;
    if (character === "(" || character === "[" || character === "{") depth += 1;
    if (character === ")" || character === "]" || character === "}") depth -= 1;
    index += 1;
    if (depth === 0) return index;
  }
  return css.length;
}

/** Drops an `@import` prelude through its `;`, a trailing block, or the enclosing `}`. */
function skipAtRule(css: string, start: number): number {
  let depth = 0;
  let index = start;
  while (index < css.length) {
    const next = skipAtomic(css, index);
    if (next !== index) {
      index = next;
      continue;
    }
    const character = css[index];
    if (depth === 0 && character === ";") return index + 1;
    if (depth === 0 && character === "}") return index;
    if (character === "(" || character === "[" || character === "{") depth += 1;
    if (character === ")" || character === "]" || character === "}") {
      depth -= 1;
      if (depth === 0 && character === "}") return index + 1;
    }
    index += 1;
  }
  return css.length;
}

/** Comments, strings, and escapes are opaque to bracket matching. */
function skipAtomic(css: string, index: number): number {
  const character = css[index];
  if (character === "/" && css[index + 1] === "*") {
    const close = css.indexOf("*/", index + 2);
    return close === -1 ? css.length : close + 2;
  }
  if (character === '"' || character === "'") return consumeString(css, index).end;
  if (isValidEscape(css, index)) return consumeEscape(css, index + 1).end;
  return index;
}
