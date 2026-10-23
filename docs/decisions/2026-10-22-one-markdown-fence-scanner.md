# One fence scanner for highlighting, Enter and completion

Three call sites decided "is this line inside fenced code?" with three different rules.
`MarkdownSyntaxParser.expandFencedCodeContext` (SyntaxKit, visible-range highlighting)
toggled on any line starting with three backticks or tildes, so ```` ``` ```` inside a
`~~~` block ended it, and it cut one `NSString.substring` per line from the start of the
document: about 16 ms per highlight with the viewport at the end of
`Fixtures/large-1mb.md` in a release build. `CodeFenceEditing.isClosingFence` (Enter, on
the main thread) toggled on any line whose trimmed text started with three backticks,
ignored `~~~`, and took the same per-line substrings from the bridged `NSTextStorage`
string. `CompletionEngine`'s `isInsideFencedCodeBlock` matched marker and length
correctly but also copied a substring per line.

`MarkdownFenceScanner` in MarkdownCore is now the only definition (agent.md §6.2). It
follows CommonMark §4.5 line by line: a closing fence is the opening character, at least
as long, with only spaces and tabs after it; a backtick opener whose info string holds a
backtick is not a fence; a leading `---`/`+++` frontmatter block closed by the same marker
is skipped, which the parser's separate frontmatter scan already assumed. Indentation is
an option: highlighting and completion keep CommonMark's three spaces, while Enter
accepts any spaces and tabs as before so fences inside list items still close.

The scan reads a native string's contiguous UTF-8 with `memchr` per line and looks only
at the first characters of each line; UTF-16 offsets in and out go through the standard
library's index breadcrumbs (O(1) for ASCII). Bridged strings are read as UTF-16, in place
when `CFStringGetCharactersPtr` exposes the buffer, otherwise from one copy. The paired
A/B in `docs/perf/2026-10-22-one-fence-scanner.md` measured, at the end of the 1 MiB
fixture in release builds, 16.0 → 0.97 ms per visible-range expansion and 27.4 → 1.19 ms
for Enter on an `NSTextStorage` string.

Behavior changes: Enter after ```` ``` ```` inside any open fence (including `~~~`) no
longer inserts a closing fence; ```` ``` ```` inside `~~~` no longer ends the block for
highlighting; a "closing" line carrying an info string (```` ```js ````) no longer closes;
```` ```a`b ```` is prose, not an opener, for highlighting and completion.

Alternatives: reuse the tree-sitter tree (rejected: highlighting deliberately parses only
the visible fragment, and the scan is what finds that fragment's fence context); keep three
scanners and only fix each rule (rejected: they already diverged three ways);
`MathInsertionContext`'s fence logic (not reused: it is command-only and answers a
different question, so it stays as is); a per-revision cache of fence state (deferred: one
`memchr` pass is about 1 ms at 1 MiB, and a cache kept across edits needs its own
invalidation).
