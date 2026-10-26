# PR #156 review round 2 — 2026-10-26

All three findings in pending review `5650927486` are adopted.

- A writer-busy save response cannot finish an already-issued capture. Keep the
  background assertion until that capture completes or its expiration handler
  runs. Recovery persistence failure also preserves an existing writer's time;
  clean/refused/no-document requests end immediately. Generation checks ignore
  stale expiration/completion callbacks.
- Create Recent bookmark data with default options while the grant is active.
  Resolve without implicit scope start, then keep the existing explicit
  `AccessGrant` start/stop admission pair. Real provider restoration remains OPEN.
- Make [results.md](results.md), [runs.json](runs.json),
  [ipa-receipt.json](ipa-receipt.json) and
  [final-check-output.md](final-check-output.md) canonical for implementation
  `e572d16f960233f525a2d8c60b81e2e48df05941` and its single freshly built IPA/fixture hash.
  Preserve the original 2026-10-08 files byte-for-byte as historical receipts.

Validation: complete app-hosted XCTest 29/29, including five background
regressions; Foundation 10/10; both negative mutations detected; fixture
packager 3/3; fresh unsigned arm64 IPA and ZIP fixture validation. All native
commands used the shared lock; failed and passing complete attempts are retained.
The test-cleanup failure and later source changes are explained in the canonical
results. Owner device, Files/iCloud, IME, install, performance and accessibility
gates remain OPEN. No production target wiring is introduced.
