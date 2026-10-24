# WYSIWYG Stable-Promotion Dogfood Checklist

> **Owner-run. Not started.** `docs/wysiwyg-release-checklist.md` D.4 needs this checklist
> signed off before WYSIWYG leaves Experimental. Agents cannot supply it: agent.md §13
> makes IME correctness non-negotiable, and these checks need physical input, a real IME,
> VoiceOver and real documents. The automated re-verification is
> `docs/wysiwyg-promotion-audit.md`.

Run the checks on a build of the promotion branch, rebased after the click-layout PR
(`phase3-wysiwyg-click-layout`) has merged. Use it for real writing, not only these steps.
File each problem as a GitHub issue and link it in the record below. A check fails if
source text changes in a way you did not type, the caret lands somewhere you did not
click or arrow to, or the app stalls.

**Setup:** a folder workspace with a real post that has headings, `**bold**`, `*italic*`,
`~~strike~~`, `` `code` ``, lists, quotes, inline `[links](https://…)`, a local PNG or JPEG
image `![alt](assets/x.png)`, and a reference link `[text][ref]`. Settings › Editor ›
WYSIWYG mode is on (the new default). Select WYSIWYG from the toolbar layout picker.

## 1. IME at fold boundaries (blocking)

- [ ] **Zhuyin – Traditional:** compose and commit 中文 immediately before and after
  `**bold**`, inside the bold text, at the start of a heading, before and after inline
  code, at the start and end of link text, right after a link's hidden `](url)`, and
  immediately before and after an image thumbnail. Also cancel one composition with Esc.
  Pass: committed text is exactly what you chose, no stray spaces or newlines, the caret
  stays where you typed, the candidate window sits at the caret, and folds come back after
  the commit.
- [ ] **Pinyin – Traditional:** the same positions and pass criteria.
- [ ] **Harness rerun (owner-run, R9):**
  `cd Packages/EditorKit && PLAINSONG_RUN_ACTUAL_IME=1 swift test --filter WYSIWYGActualIMEEventGateTests`
  with both input methods enabled. Pass: 10 tests, 0 failures, neither input method
  skipped. The last run was 2026-07-12, before STTextView 2.4.1.

## 2. Pointer (blocking; needs the click-layout PR)

- [ ] Click inside bold, strike, inline-code and link text, and on a heading. Pass: the
  caret lands where you clicked and only the touched span reveals its Markdown.
- [ ] Click exactly at the edges of folded spans and just after a link. Pass: the caret is
  never trapped inside hidden delimiters or a hidden URL.
- [ ] Drag-select across several folded spans and a link, then Shift-click to extend. Pass:
  the selection covers what you dragged over.
- [ ] Double-click a word and triple-click a paragraph inside folded text. Pass: native
  word and paragraph selection.
- [ ] In a document of about 1 MiB (`Fixtures/large-1mb.md`), click near the end. Pass:
  no visible pause (the known whole-document layout limit is gone).
- [ ] With line numbers on (Settings › Editor), repeat a few clicks. Pass: same results.

## 3. Copy and paste

- [ ] Copy a selection that spans whole folded spans, one that is only visible text, and
  one that ends inside a hidden link URL; paste each into a plain-text editor. Pass: you
  get the exact raw Markdown of the selected range, never rendered text.
- [ ] Paste plain text and a URL into folded and revealed spans. Pass: the source changes
  only by the pasted text.

## 4. VoiceOver basics

- [ ] Turn on VoiceOver (⌘F5) and read a paragraph with folded spans, a link and an image.
  Pass: VoiceOver reads the raw Markdown source, the image is announced by its alt text
  (or "Image" when the alt is empty), and VO navigation moves the caret sanely.
- [ ] Move by character across a folded `**`. Pass: no stuck caret and no silent jumps.

## 5. Image thumbnails

- [ ] A local PNG/JPEG/GIF/WebP in the workspace shows a bounded thumbnail; a missing file
  shows the alt placeholder without shifting other lines.
- [ ] Replace the image file in Finder. Pass: the thumbnail refreshes.
- [ ] A remote `https:` image, an SVG and a reference image stay raw Markdown.
- [ ] Open the same post as a single file (File › Open, not as a folder). Pass: images
  stay raw.
- [ ] Click a thumbnail. Pass: the raw `![alt](src)` reveals; nothing opens.

## 6. Links

- [ ] Inline links fold to styled text; arrow right through the end of the link text.
  Pass: the caret never stops inside the hidden URL.
- [ ] Edit a URL after it reveals, then Undo and Redo. Pass: plain text edits, the fold
  returns.
- [ ] Reference links `[text][ref]` and autolinks `<https://…>` stay raw.

## 7. Large documents

- [ ] Open `Fixtures/large-1mb.md` in WYSIWYG; scroll top to bottom and type at the top,
  middle and end. Pass: typing keeps up, folds appear while scrolling, no beachball.
- [ ] Switch to source + preview and back. Pass: no long stall.

## 8. Find and Replace in WYSIWYG

- [ ] Find (⌘F) a word inside folded bold and inside link text. Pass: matches highlight
  and Return walks through them.
- [ ] Replace on a match inside a folded span: the first press selects and reveals it, the
  next press replaces it. Pass: only that raw text changes, and Undo restores it.
- [ ] Replace All for a word that occurs in plain, bold, link and image-alt text. Pass:
  one Undo step reverts everything; folds and thumbnails return.

## 9. Switching layouts

- [ ] ⌘⇧P cycles source + preview → source only → WYSIWYG → source + preview, and the
  View menu item and toolbar picker show the current mode. No "Experimental" label appears
  anywhere (Settings, View menu, toolbar).
- [ ] Switch layouts while text is selected and while composing with an IME. Pass: no
  text change and no lost composition.
- [ ] Quit in WYSIWYG and relaunch. Pass: WYSIWYG restores with the same document.

## 10. Fallback

- [ ] In WYSIWYG, turn off Settings › Editor › WYSIWYG mode. Pass: the window drops to
  source only, the fallback banner explains why, the text is unchanged, and ⌘⇧P now cycles
  only source + preview and source only. Turn it back on: WYSIWYG returns to the cycle.
- [ ] Dismiss the banner. Pass: it goes away and does not come back on its own.
- A real mechanism failure (TextKit 2 content storage unavailable) and a relaunch with
  WYSIWYG persisted while the switch is off cannot be triggered from the UI; they are
  covered by `AppStateTests.testWYSIWYGMechanismFailureFallsBackToSourceOnlyWithoutChangingText`,
  `AppStateTests.testPersistedWYSIWYGFallsBackToSourceOnlyWhenExperimentalFlagIsDisabled`
  and `WYSIWYGPromotionAppStateTests.testOptOutStoredBeforeThePromotionStillTurnsWYSIWYGOff`.

## Record

| Field | Value |
|---|---|
| Dates of use | |
| Build (commit) | |
| macOS / Mac | |
| Input methods | |
| Documents used | |
| Issues filed | |
| Result | |
| Signed off by | |
