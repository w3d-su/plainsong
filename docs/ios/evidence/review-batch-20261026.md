# iOS historical-PR review follow-up — 2026-10-26

The later [round-two receipt](review-round2-20261026/README.md) adopts all eight new findings, including freshly regenerated lockfiles. The following record is historical for its stated source.

The four delivery PRs had already reached main through the phase-A integration.
This follow-up applies their remaining review repairs to current main while
preserving later generation, observation, fixture and editor-delay work.

| PR / pending review | Disposition | Updated delivery head |
|---|---|---|
| #187 / 5648967994 | Accept: retain both v1 failures and the later successful raw probes in execution order; platform causality remains unproven | `fb66039ba1da2f4a5692ea80d3d69fead5f029cd` |
| #164 / 5649020476 | Accept all four: scoped bookmark refresh, clean proposal close, new retirement recovery receipts, root observation | `c9a25dbd392d16d7e43fb91f209a6815b0e4e64b` |
| #157 / 5649056231 | Accept graph clarification and invariant-preserving comment cleanup; lockfile rewrite not reproduced by ordinary/locked Swift 6.4 resolution | `e82fb43d46f2878a5f6ea2151286001d7d921403` |
| #156 / 5649036811 | Accept all three: fixture packaging, replacement failure recovery, system grep in mutation checks | `2fbdfb6c5c3c488e546e032bc6b95603e03d62ba` |

Detailed receipts: [WorkspaceKitIOS](review164-20261026.md),
[C0 comments and package resolution](lane-13/review-20261026.md),
[M0 historical branch](m0/review-20261026.md).

Current-main validation ran on clean `5984dee505007f6af2ee478bdf9a2b625d6580dc`:

- Official `make ios-test`: **504 passed, 0 failed, 0 skipped**, six compiled test
  images, resource parity, all **137** required names (including all twelve added
  WorkspaceKitIOS regressions), immutable required-name copy and source verification.
- Main M0 prototype hosted suite: **24 passed, 0 failed, 0 skipped**, including
  malformed open, close refusal, late-source preservation, candidate grant lifetime,
  successful replacement and bundled fixture cases.
- iOS tooling: **44/44** on the independent rerun. The earlier attempt contended
  with the active native run's canonical lock and remains preserved as failed.
- Main fixture packager negative guards: **3/3**. Pinned SwiftFormat 0.62.1:
  all **23** changed Swift files passed. SwiftLint without cache exited 0 with
  nonblocking warnings. Initial cached lint lacked cache-write permission.
- Thirteen frozen-file hashes verified; the nine Swift comment cleanups preserve
  all declarations and semantic invariants. The published C0 tag remains unchanged.

The later receipt/link commit changes documentation only. Captured module inputs
and all nineteen M0 prototype inputs remain byte-identical to these passing runs.
The historical #156 unsigned IPA audit belongs to its separate source head; no
current production release IPA or physical-device acceptance is inferred.

Complete local artifacts: `/private/tmp/plainsong-review-main-native-20261026/`
and main worktree `Prototypes/iOSM0/Artifacts/20261026T091306Z-test-E0B18A3C/`.
The official module runner's owned post-case `simctl diagnose` child was stopped
after all six functional bundles completed and its PID/parent/output were rechecked.
The action is retained in `post-case-diagnostic-interruption.json`; the runner then
finalized its complete xcresult, required-name/source gates and exit 0 itself.

Independent source review covered both historical fixes and the main port. Claude
review, current-head CI and owner device/signing/performance/accessibility gates
remain separate. No PR was merged, no force-push was used, and the owner checkout
was preserved.
