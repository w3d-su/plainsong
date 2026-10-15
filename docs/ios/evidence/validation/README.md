# iOS acceptance harness — phase B receipt

Parent: PR #164 head `59f374ff9341289b91c0a4090b216dcf16510797` on `codex/ios-review-fixes-20261013`.

This receipt covers the Mac component package only. It does not close product acceptance, M0, or phase C.

## Diagnosis

`59f374ff` has no `IOSAcceptanceTests` target. Production composition still publishes nil editor, document, workspace, preview, and asset capabilities and shows the unavailable scaffold. Review 2026-10-13 recorded real preview-bundle ready as FAIL. Historical results on other heads (public simulator 294/294, storage 46/46, Mac CI run 38372199432) are not results for this harness.

## What ran

| Item | Result |
|---|---|
| Local automated component suite | PASS — 18 tests, 0 failures, exit 0 |
| Hosted UI smoke | BLOCKED — source only, not compiled or run |
| Simulator XCUI / device | not run |
| Exact-head CI for this branch | not run |
| Performance samples | not collected |
| Product gates | OPEN or BLOCKED — none PASS or FAIL |

Command, serialized with `/usr/bin/lockf -k -t 1200` on `/private/tmp/plainsong-xcodebuild-test.lock`:

```sh
swift test --package-path IOSAcceptanceTests \
  --build-path /private/tmp/plainsong-ios-11-validation-harness-build \
  --scratch-path /private/tmp/plainsong-ios-11-validation-harness-build
```

The build path is outside the repository. This is not `make ios-test` and it does not set `IOS_RUNNER_LOCK_*`.

Window: start `2026-10-15T09:39:57Z`, XCTest suite `2026-10-15 17:41:28 +0800`, end `2026-10-15T09:41:29Z`. Build 3.87 seconds. Suite 0.809 seconds. Host `arm64e-apple-macos14.0`. Swift Testing then reported 0 tests in 0 suites; the XCTest count is the result.

Log: `docs/ios/evidence/validation/component-run-20261015.log`

SHA-256: `8cc5b760e64b6a319575031208ff043ff1d92ee308badf5e78e8b8a394b2aff2`

The same bytes were at `/private/tmp/plainsong-ios-11-validation-harness-swift-test-2.log` when this receipt was written. An earlier wrapper printed a passing 18/0 suite and then died on zsh's read-only `status` variable. That log is not this receipt.

Required names, all present in the log:

`docs/ios/evidence/validation/required-component-tests.txt`

## Named positive results

- Pinned manifest: 75 records, and `App/Resources/preview/` is an exact set of 64 non-empty regular files.
- Unicode single replace of the current `👩‍💻` match to `工程師` changes only that match, collapses the selection, and counts one undo registration on the harness probe.
- Frontmatter writeback keeps a quoted title `標題: "quoted"`.
- Same-version document switch moves `PreviewController.isCurrent` from root A to root B. This is a stale-root check. It does not wait for WebKit ready and is not a bundle-render PASS.
- `Scripts/ios/ios-test-results.py` exits 65 on empty nodes and on an all-skip document. A synthetic Passed document exits 0. That last exit is a script fixture, not an executed UI test.

## Named negative results

- Empty, hostile, tampered, and symlink resources fail closed (`O_NOFOLLOW`).
- Lease cleanup removes only its own temp root. A sibling `plainsong-user-recents-*` directory stays. A foreign directory without the lease marker throws `missingOwnership` and is not deleted.
- `BoundedWait` records `.timedOut(nanoseconds: 20_000_000)` instead of succeeding.
- An older save acknowledgement leaves live text `N+1 繁中` dirty. A later order-1 completion cannot clean an order-2 acknowledgement.
- A dirty draft is not replaced by persisted bytes. On a separate session, `markSaved(text: "N")` would clobber the live draft; the oracle never calls `markSaved`.
- Stale source, a different document id, a bumped selection generation, a missing pattern, and a replacement containing a newline leave source, selection, and undo registrations unchanged.
- Malformed YAML makes `Frontmatter.updating` return nil and leaves the source unchanged.
- A single-file grant for `note.md` does not authorize the parent, `assets/pixel.png`, or `../secret`. The same file URL under another workspace id is not the same grant.
- No product gate is `.pass` or `.fail`. The debug seam stays disabled, including `releaseCanEnable() == false`.
- Sixty `textDidChangeOnly` samples stay open: `textDidChange duration is not input-to-screen`. One visible sample stays open: `fewer than 60 visible-presentation samples`. Sixty simulator input-to-screen samples and sixty owner-idle render-completion samples are `.diagnostic(count: 60)`, not a product pass.

## Still open

| Gate | Status |
|---|---|
| Launch → edit → preview → save → reopen | BLOCKED — scaffold only, UI target unwired |
| iPhone / iPad regular / iPad compact / selection across layout | OPEN |
| Files, iCloud, image rollback, VoiceOver, hardware keyboard, device IME | OPEN |
| Preview bundle render | OPEN — hash preflight is not WebKit ready |
| Input-to-screen, visible highlight, render completion | OPEN — no samples |
| Owner re-signed install | OPEN |
| Phase C on a lane 13 integration head | not started |

Manual rows: `manual-matrix.md`. Lane 12 target proposal: `wiring-proposal.md`. Hosted case, not run: `required-hosted-smoke.txt`.
