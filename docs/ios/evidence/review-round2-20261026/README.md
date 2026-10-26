# PR review round two — 2026-10-26

All eight findings in the supplied pending reviews are adopted. #219 has no
review and remains unchanged. These follow-ups update the historical PRs and carry
the applicable code/metadata/documentation repairs to main-facing #221.

| PR / review | Disposition |
|---|---|
| #221 / 5650912026 | Hold newly completed reload proposals during close; failed provider close replays only after closing ends and current authority is verified. Two attached-editor regressions detect the original failure. |
| #164 / 5650939520 | Keep retryable bookmark failures available; fence root refresh and listing-offline publication by the latest request/current grant. Ten access/root regressions, plus the close repair, cover both branches. |
| #187 / 5650845096 | Retain `jsErrors=2` as a thrown-poll counter, not proof of page exceptions; retain the 4.417469-second WebContent launch observation. |
| #157 / 5650867990 | Regenerate three origin hashes with actual SwiftPM. Preserve every pin; locked resolution is byte-identical. Main's EditorKit origin is generated from its own different manifest. |
| #156 / 5650927486 | Keep background time through the active capture or expiry, including recovery failure; use default bookmark creation with explicit scope pairing; make one source/IPA/fixture receipt canonical and preserve older records as historical. |

## Current main source validation

Clean implementation `047ac873321c9608fa1c352bac8d1a878985e4e0`:

- Official `make ios-test`: **516 passed, 0 failed, 0 skipped**; all **149 required
  names**, six compiled test images, resource parity, 793 source input records and
  immutable required-name/source verification. Runner exit 0, `source_dirty=false`.
- Separate main M0 prototype: **32/32**, no failures/skips, normal runner exit 0;
  its extra WorkflowTests and main Fixture/Delay UI are retained. Fresh device IPA
  and canonical source/fixture/hash records are in `main-m0-receipt.json` and
  [the current M0 receipt](../m0/results.md).
- iOS tooling **44/44**. Pinned SwiftFormat 0.62.1: all 12 changed Swift files pass.
  SwiftLint exit 0 with existing nonblocking warnings. All three lockfiles change
  only origin hashes, preserving complete pins and other fields.
- The 12 new module names are required by the public runner. Existing dirty-source,
  revocation, deferred-observation, generation and stale-token barriers remain.

The two new close tests fail on the original production code before the repair
(two cases, five assertions, exit 65). Its complete log and local xcresult are
retained; this small initial probe did not capture a run-bound source manifest.
Historical #164 has a separate complete **131/131** pass and a source-bound
negative run executing ten access/root names (**9 expected failures, 1 pass**):
[full receipt](https://github.com/w3d-su/plainsong/blob/12c8c1dbe8c6738e952c54580c6a73212548c0e1/docs/ios/evidence/review164-round2-20261026/README.md).
Historical #156 has its separate **29/29** source/IPA receipt at `e572d16`; its
artifact hash must not be substituted for the main M0 artifact.

The official module run stalled in its owned post-case `simctl diagnose` after
all six functional bundles and all 516 cases completed. Only that diagnostic
child received SIGINT after its PID, parent, runner and canonical output were
revalidated. No test host, simulator or xcodebuild was signaled. The official
runner then completed the xcresult, named/source gates and exit 0 itself. Full
intervention details are retained in `post-case-diagnostic-interruption.json`.
M0's two public runners completed normally without intervention.

The later publication changes evidence only; module and prototype inputs remain
byte-identical to their captured passing runs. Exact publication-head CI is a
separate GitHub check. No macOS full test run is inferred from this iOS-only local
suite. Independent source and receipt reviews pass; Claude/maintainer acceptance
and owner physical-device/signing/Files/IME/background/performance/accessibility
gates remain OPEN. No merge or force-push; owner checkout preserved.

## Retained artifacts

`native/*.gz` contains complete build/test logs, source, admission/resource checks,
required names, named outcomes and runner receipt. `m0/*.gz` contains the main
prototype test log, test/IPA manifests and summary. `checksums.json` binds every
packet member. Full xcresults and the actual unsigned IPA stay at their original
local paths recorded in these manifests and under:

`/private/tmp/plainsong-review-round2-221-evidence/`

Historical #187 packet checksums and exact v5 log lines pass 26/26. Historical and
main lockfile regeneration/locked-resolution logs remain in
`/private/tmp/plainsong-review157-round2-state/` and
`/private/tmp/plainsong-review221-lockfile-state/`.
