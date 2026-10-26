# Completion metadata and the inspector's frontmatter reuse work whose inputs did not change

Every typing pause (250 ms) rebuilt completion metadata from scratch: up to 50 sibling
Markdown files were opened through the anchored walk, read whole, SHA-256 hashed and
scanned for frontmatter keys, and `completionWorkspace` was assigned even when nothing
changed, so every `AppState` observer re-rendered. The inspector consumed the session's
undebounced text stream and ran `Frontmatter.parse` (Yams, plus a copy of the text after
the block) in `body` on every keystroke while it was visible.

Now the workspace-derived half of completion metadata (`CompletionWorkspaceBase`: snapshot
paths and sibling frontmatter keys) is cached in `AppState` per installed capture
generation and current file location, and a typing pause recomputes only heading anchors
and MDX component names. Sibling frontmatter is read as a bounded 32 KiB prefix with no
digest, inside one security scope for the pass. The result is assigned only when it
differs literally (`==` on strings is canonical equivalence, which would hide an NFC/NFD
rename). The inspector debounces the stream by 150 ms and memoizes the parse on the prefix
of the text that determines it (`FrontmatterParseMemo.determiningPrefix`, tested to parse
exactly like the whole text). An inspector edit is computed from `session.text` at the
moment of the edit instead of the last stream value, so the debounce cannot apply an edit
to stale text, and is shown immediately.

Alternatives: keeping the full reads but skipping the publish when equal (rejected: the
50 reads stay on every pause, a median 67 ms of utility-queue work in
`docs/perf/2026-10-22-app-publish-hygiene.md`); caching keyed on `workspaceGeneration`
instead of the installed capture generation (rejected: the generation advances before a
reload installs its capture, so a refresh in that window would label the old snapshot
with the new generation); reading sibling frontmatter through `MarkdownFileStore` with a
size cap (rejected: it still hashes, and a cap that refuses large files drops their keys);
re-parsing the frontmatter off-main on every change (rejected: the parse is cheap once
memoized; the per-keystroke cost was the inspector re-render itself).
