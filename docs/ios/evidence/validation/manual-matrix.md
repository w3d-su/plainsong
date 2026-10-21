# iOS / iPadOS manual acceptance matrix

Head under test must be recorded before any row changes. Every row below is **OPEN** on `59f374ff9341289b91c0a4090b216dcf16510797` plus this harness. Simulator screenshots, the scaffold UI test, and Mac component tests do not check these boxes.

Record for each attempt: device model, OS, thermal state, Low Power Mode, build configuration, source head, fixture SHA-256, and whether Xcode or a simulator was busy. Keep failed attempts. A later pass does not erase an unexplained race.

## Launch and layout

| Check | Status | What a pass must show |
|---|---|---|
| iPhone launch → open synthetic file → type → dirty source → preview → save → reopen | OPEN | Same UTF-16 text, selection, revision, and undo stack after reopen. Not the scaffold screen. |
| iPhone editor / preview switch | OPEN | Source, selection, undo, and document identity stay put. |
| iPad regular width, side by side | OPEN | Both panes show the same document. Focus changes do not retarget another editor. |
| iPad compact width, stacked switch | OPEN | Rotation and width changes keep source, selection, undo, and identity. |

## Input

| Check | Status | What a pass must show |
|---|---|---|
| Traditional Chinese Zhuyin candidates | OPEN | Marked text commits the chosen candidate. Undo restores the pre-composition source. Programmatic marked text is not a substitute. |
| Pinyin candidates | OPEN | Same as Zhuyin, on a device keyboard. |
| Emoji and ZWJ family | OPEN | One insertion, one undo group, no extra scalar left behind. |
| Paste | OPEN | One undo group. Selection ends after the pasted text. |
| Hardware keyboard | OPEN | Type, undo, find, and single replace reach the focused editor only. |

## Files and recovery

| Check | Status | What a pass must show |
|---|---|---|
| Local Files in-place open/save | OPEN | Bytes on disk match the editor. No copy-into-container. |
| iCloud Drive, placeholder, offline | OPEN | Waiting or download failure is not an empty document. |
| Read-only and expired bookmark | OPEN | Typed failure, reauthorization entry, original bytes kept. |
| External move/delete | OPEN | Recovery can be read back. The draft is not discarded. |
| Save N blocked, then edit N+1, then the old completion returns | OPEN | Live text stays N+1 and stays dirty. The old success does not mark it clean. |
| Dirty external change | OPEN | Conflict UI. Local draft and recovery snapshot kept. No overwrite. |
| Background, termination, relaunch | OPEN | Recovery reopens the dirty draft. An older completion cannot erase it. |
| Single-file grant | OPEN | Parent and siblings are not read. A missing folder grant does not invent one. |

## Authoring and images

| Check | Status | What a pass must show |
|---|---|---|
| Frontmatter literal round trip | OPEN | Quoted strings and lists survive parse and writeback on device. |
| Invalid YAML | OPEN | Source bytes unchanged. No new undo group. |
| Unicode find and one replace | OPEN | One native undo. A stale match or lost selection/document authority changes nothing. |
| Image cancel and write failure | OPEN | No Markdown insertion. Rollback deletes only that operation's leaf. |
| Undo after an inserted image | OPEN | Source undo does not delete the image file. |

## Preview, accessibility, performance, install

| Check | Status | What a pass must show |
|---|---|---|
| Real preview bundle ready | OPEN | `bundle.js` loads from the committed preview directory. A synthetic page is not ready. |
| Stale render / asset root | OPEN | Document switch at the same version drops the previous root's bytes. |
| Remote images, script, SVG, path escape | OPEN | Defaults stay closed. A failure does not widen the root. |
| VoiceOver on iPhone and iPad, both orientations | OPEN | Focus order reaches editor, preview, and file controls. A screenshot is not a pass. |
| `perf-100kb.md` input-to-screen | OPEN | p95 under 16 ms from key to visible glyphs. At least 60 samples after warm-up. `textDidChange` time does not count. |
| Visible highlight | OPEN | Under 50 ms for the visible range. |
| 100 KB preview render completion | OPEN | Under 100 ms, with the 150 ms debounce recorded separately. |
| `large-1mb.md` | OPEN | Correct text and responsive editing. Do not reuse the 100 KB render budget. |
| Owner re-signed install | OPEN | The unsigned tooling IPA is not this head's binary. |

## Performance sheet

For each device and fixture, warm up, then take at least 60 fixed-position samples. Keep the raw samples. Skip the conclusion if thermal state is serious, Low Power Mode is on, or another Xcode/simulator job is running. Hosted CI and simulator numbers stay diagnostic.
