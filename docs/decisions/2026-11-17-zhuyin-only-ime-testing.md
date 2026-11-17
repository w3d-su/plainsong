# IME testing uses Traditional Chinese Zhuyin only; Pinyin is no longer tested

Owner decision on 2026-11-17, made while preparing the #213 WYSIWYG dogfood. Every owner
IME check had to run twice, and each actual-IME harness run needed a second input source
enabled; the owner no longer wants Pinyin in any test.

What changed:

- agent.md §13 now names Zhuyin as the required marked-text input.
- `WYSIWYGActualIMEEventGateTests` loses its three Pinyin tests (fold, link and image
  boundaries) and their script, keys and input-source matcher. The class now has 7
  tests: 4 opt-in (the three Zhuyin event-stream tests and the event-posting access
  check) and 3 that always run (the link- and image-boundary fixture checks and the
  check that selection keys stay with the input context while composing).
- `WYSIWYGIMESpikeTests` drops its synthetic Pinyin marked-text script and is renamed
  `testZhuyinMarkedTextRoundTripsAtFoldBoundaries`.
- Open gates that asked for a Pinyin run now ask for Zhuyin only: find-field F6 (§8
  smoke), Replace R6, table T5, the windows owner smoke, risk R9, the 1.0 scope, the
  iOS 1.0 device pass (`docs/ios/device-pass.md` §D), and the iOS M0 checklist and
  integration-ledger IME items. The standing IME rules in `docs/wysiwyg-design.md` and
  `docs/ios/README.md` say Zhuyin too.

Passed gates and dated evidence (link L5, image thumbnails, the 2026-07 owner runs,
iOS evidence receipts, the superseded iOS validation matrix, `docs/codex-handoff.md`)
keep their Pinyin results as recorded. The lane 04 device-acceptance record keeps its
Pinyin line, struck through and marked superseded by this decision.

Cost: Pinyin composes Latin letters (`tai`) where Zhuyin composes Bopomofo. Latin
marked text away from folds stays covered by `MarkdownEditorInputTests` (`draft`) and
`WYSIWYGIMESpikeTests.testReservedMarkedTextReturnDoesNotDiscardMarkedTextInEmptyDocument`
(`ab`). What is no longer tested is Latin marked text at fold, link and image
boundaries, and a real input method that composes Latin letters, including marked
text that shrinks from 3 UTF-16 units to 1 on commit.

Alternatives: keep the automated Pinyin harness and synthetic case while dropping only
the manual Pinyin runs; not chosen, because the owner asked for no Pinyin testing at all.

Supersedes: the "Zhuyin/Pinyin" wording of agent.md §13 and every open gate that
required a Pinyin run.
