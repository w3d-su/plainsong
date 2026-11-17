# IME testing uses Traditional Chinese Zhuyin only; Pinyin is no longer tested

Owner decision on 2026-11-17, made while preparing the #213 WYSIWYG dogfood. Every owner
IME check had to run twice, and each actual-IME harness run needed a second input source
enabled; the owner no longer wants Pinyin in any test.

What changed:

- agent.md §13 now names Zhuyin as the required marked-text input.
- `WYSIWYGActualIMEEventGateTests` loses its three Pinyin tests (fold, link and image
  boundaries) and their script, keys and input-source matcher. The opt-in run is now
  7 tests: the three Zhuyin event-stream tests, the event-posting access check and three
  fixture checks.
- `WYSIWYGIMESpikeTests` drops its synthetic Pinyin marked-text script and is renamed
  `testZhuyinMarkedTextRoundTripsAtFoldBoundaries`.
- Open gates that asked for a Pinyin run now ask for Zhuyin only: find-field F6 (§8
  smoke), Replace R6, table T5, the windows owner smoke, risk R9, the 1.0 scope, and the
  iOS M0, validation-matrix and integration-ledger IME items.

Passed gates and dated evidence (link L5, image thumbnails, the 2026-07 owner runs,
iOS evidence receipts, `docs/codex-handoff.md`) keep their Pinyin results as recorded.

Cost: Pinyin composes Latin letters (`tai`) where Zhuyin composes Bopomofo, so a
regression that only shows with Latin marked text is no longer caught by any test.

Alternatives: keep the automated Pinyin harness and synthetic case while dropping only
the manual Pinyin runs; not chosen, because the owner asked for no Pinyin testing at all.

Supersedes: the "Zhuyin/Pinyin" wording of agent.md §13 and every open gate that
required a Pinyin run.
