# iOS acceptance harness — phase B receipt

Parent: PR #164 head `59f374ff9341289b91c0a4090b216dcf16510797` on `codex/ios-review-fixes-20261013`.

This receipt covers the Mac component package only. It does not close product acceptance, M0, or phase C.

## Diagnosis

`59f374ff` has no `IOSAcceptanceTests` target. Production composition still publishes nil editor, document, workspace, preview, and asset capabilities and shows the unavailable scaffold. Review 2026-10-13 recorded real preview-bundle ready as FAIL. Historical results on other heads (public simulator 294/294, storage 46/46, Mac CI run 38372199432) are not results for this harness.

## What ran

HEAD `6d652107e4ab6007e7f941f727b7a61bd65b4d0f` lists 29 names in `docs/ios/evidence/validation/required-component-tests.txt`. Each log below stays with the commit that produced it. A complete 29-case run of this head is not retained.

| Item | Result |
|---|---|
| Local automated component records | Split by commit. `4d16e2b` ran 18 tests. `bcc8ab6` ran the full component suite **26/26**. `6d65210` ran `BoundedWaitFenceTests` **7/7**. |
| Full 29-case run of HEAD `6d65210` | **not retained** |
| Hosted UI smoke | BLOCKED — source only, not compiled or run |
| Simulator XCUI / device | not run |
| Exact-head CI for this branch | not run |
| Performance samples | not collected |
| Product gates | OPEN or BLOCKED — none PASS or FAIL |

The 29-name list adds three cases that the `bcc8ab6` log does not contain:

- `BoundedWaitFenceTests/testPreCancelCompletesOnceAndDropsALaterTrue`
- `BoundedWaitFenceTests/testCancelWhileWaitingCompletesOnceAndDropsALaterTrue`
- `BoundedWaitFenceTests/testDeadlineRacesHandlePublicationAndResumesOnce`

Those three names are in the `6d65210` fence log, together with the four fence cases already in the 26-case log. The fence log is a filtered class run. It is not the 26-case suite, and the two logs together are not a 29-case run.

### `4d16e2b` — 18 tests

Command, serialized with `/usr/bin/lockf -k -t 1200` on `/private/tmp/plainsong-xcodebuild-test.lock`:

```sh
swift test --package-path IOSAcceptanceTests \
  --build-path /private/tmp/plainsong-ios-11-validation-harness-build \
  --scratch-path /private/tmp/plainsong-ios-11-validation-harness-build
```

The build path is outside the repository. This is not `make ios-test` and it does not set `IOS_RUNNER_LOCK_*`. The `bcc8ab6` record used this same command and build path.

Window: start `2026-10-15T09:39:57Z`, XCTest suite `2026-10-15 17:41:28 +0800`, end `2026-10-15T09:41:29Z`. Build 3.87 seconds. Suite 0.809 seconds. Host `arm64e-apple-macos14.0`. Swift Testing then reported 0 tests in 0 suites; the XCTest count is the result.

Log: `docs/ios/evidence/validation/component-run-20261015.log`

SHA-256: `8cc5b760e64b6a319575031208ff043ff1d92ee308badf5e78e8b8a394b2aff2`

The same bytes were at `/private/tmp/plainsong-ios-11-validation-harness-swift-test-2.log` when this receipt was written. An earlier wrapper printed a passing 18/0 suite and then died on zsh's read-only `status` variable. That log is not this receipt. This 18-case log is the first component record. It is not the 26-case record and not a 29-case run.

### `bcc8ab6` — full component suite 26/26

`bcc8ab6010dc5ea4022aa3d9df03c1831dd0fa53`. The first run accepted a late `BoundedWait` success, replaced the first find hit when the selection was the second, and let an intermediate symlink leave the lease. This record is that fix. Its required list at that commit was 26 names.

Window: start `2026-10-15T14:37:54Z`, XCTest suite `2026-10-15 22:37:57 +0800`, end `2026-10-15T14:37:58Z`. Build 1.99 seconds. Suite 0.650 seconds. Exit 0. Executed 26 tests, 0 failures. The log has no compiler warnings. `BoundedWaitFenceTests` in this log executed 4 tests.

Log: `docs/ios/evidence/validation/component-run-20261015-v11.log`

SHA-256: `17709c2048b60ecfc5650cbaaa9e7de97e1180e0227828d99cd84fefa5900fc5`

Swift Testing again reported 0 tests; the XCTest count is the result.

- A zero timeout does not accept an immediate `true`. A `true` that arrives only after the 20 ms deadline, including a predicate that stays silent for 250 ms, is `.timedOut` and the wait returns in under 150 ms. A `true` inside the deadline still succeeds.
- The selection `{14, 5}` replaces only the second `👩‍💻`. A prefix selection, a moved selection, and a stale range leave source, selection, and the probe counter unchanged. That counter is not an `UndoManager` registration.
- `owned/linked-parent/fixture.md` is refused on read and write. The outside directory stays unchanged, and the symlink remains. A direct `open` with `O_NOFOLLOW` still followed that parent in a separate OS probe; `openat` with `O_DIRECTORY | O_NOFOLLOW` returned `ENOTDIR`. The probe is not this Swift run.

### `6d65210` — `BoundedWaitFenceTests` 7/7

`6d652107e4ab6007e7f941f727b7a61bd65b4d0f`. `bounded-wait-race/README.md` records `swift test --filter BoundedWaitFenceTests`: 7 tests, 0 failures. The suite line in the log is `2026-10-15 22:58:13`. The log ends with `fence_exit:0`. This run has no Thread Sanitizer. It does not execute the other component classes.

Log: `docs/ios/evidence/validation/bounded-wait-race/fence-tests.log`

SHA-256: `aff3e4abbb85b1718d224737359bc8276ea73906b9872786613bdebfcab59a6c`

### Isolated Thread Sanitizer probe

This probe is not an XCTest run. It is not the 18-case log, the 26-case log, or the 7-case fence log. Source hashes and the `swiftc -sanitize=thread` command stay in `bounded-wait-race/README.md`.

| Source | Log | SHA-256 | Archived result |
|---|---|---|---|
| Racy `racy-BoundedWait.swift` | `bounded-wait-race/tsan-racy-run.log` | `36ae0644e6e264c24cc87cb50278b689908a97a1ec0cc7fe44a7636be37633be` | exit **-6**. `WARNING: ThreadSanitizer: data race` at `racy-BoundedWait.swift:112` (previous write at `:116`). `PROBE_DONE` was not printed. |
| Fixed `IOSAcceptanceTests/Sources/IOSAcceptanceHarness/BoundedWait.swift` | `bounded-wait-race/tsan-fixed-run.log.gz` (gzip; digest is for uncompressed bytes) | `b8b8cb9768671f726c353d426cf351b4f0a39026101d2facc1a3a39d8d5a8a19` | exit **0**. Output is `PROBE_DONE`. The log has no sanitizer warning. |

### Full 29-case run of this head

Not retained. The file `required-component-tests.txt` on `6d65210` is the 29-name list. No log in this directory is that execution.

The checks below are the behavior in the `4d16e2b` and `bcc8ab6` component logs. They are not a 29-case execution of `6d65210`.

## Named positive results

- Pinned manifest: 75 records, and `App/Resources/preview/` is an exact set of 64 non-empty regular files.
- Unicode single replace of the current `👩‍💻` match to `工程師` changes only that match, collapses the selection, and counts one undo registration on the harness probe.
- Frontmatter writeback keeps a quoted title `標題: "quoted"`.
- Same-version document switch moves `PreviewController.isCurrent` from root A to root B. This is a stale-root check. It does not wait for WebKit ready and is not a bundle-render PASS.
- `Scripts/ios/ios-test-results.py` exits 65 on empty nodes and on an all-skip document. A synthetic Passed document exits 0. That last exit is a script fixture, not an executed UI test.

## Named negative results

- Empty, hostile, tampered, leaf-symlink, and ancestor-symlink resources fail closed. `O_NOFOLLOW` on the leaf is not the ancestor check.
- Lease cleanup removes only its own temp root. A sibling `plainsong-user-recents-*` directory stays. A foreign directory without the lease marker throws `missingOwnership` and is not deleted.
- `BoundedWait` records `.timedOut(nanoseconds: 20_000_000)` for an immediate `false`, a late `true`, and a predicate that has not replied. A `true` observed at or after the deadline is discarded.
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
