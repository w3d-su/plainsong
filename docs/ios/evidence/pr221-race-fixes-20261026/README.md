# PR #221 race repairs — 2026-10-26

Implementation: `151ac66067745594480123dcf294e0fe533a97b4`. Publication after this commit changes evidence
only; the native source fingerprint and every prototype input remain unchanged.

## Repairs

- Deferred external reloads recheck current store operation/revision/grant and
  lifecycle immediately before installation. Closing holds the operation without
  retiring it; failed close resumes once. C0 declarations remain unchanged.
- Root notice keys are typed and disjoint from exact-byte child paths, so child
  notifications cannot coalesce away root revocation.
- M0 observes replacement candidates before open. A candidate invalidated while
  the old document closes is refused; the original editor is retained/reopened.

## Complete positive runs

`make ios-test IOS_DESTINATION='platform=iOS Simulator,id=59CB04BD-26CC-4841-8D06-E75A2EDEBC66'`
passed **531/531**, zero failures/skips, all **164 required names**, runner exit 0.
All six compiled test images and resource parity passed; **798 source inputs**
are bound by fingerprint `c5dbd6c231e5357088d8c055506cc342cf30e2f12029e83229292e494b926297`.
The official runner completed normally without interrupting any diagnostic or host.

`Prototypes/iOSM0/Scripts/run.sh test 59CB04BD-26CC-4841-8D06-E75A2EDEBC66`
passed **35/35**, zero failures/skips, normal runner exit 0. All 35 required names
were separately checked against actual xcresult outcomes. A fresh official `ipa`
run bound the same 23 prototype input hashes and exited 0.
IPA SHA-256: `b4fe8eb6630b7aea62e5169fb873f04b858dc7ff8f21e5d76014d0fb5d676bd9`.
ZIP CRC, exact 243-byte fixture, arm64, iOS 26, iPhone/iPad and unsigned checks pass.

Tooling **44/44**, packager guards **3/3**, pinned SwiftFormat 0.62.1 and
`git diff --check` pass. SwiftLint with `--no-cache` exits 0 with existing warnings;
its initial sandbox cache-write failure is retained separately.

## Negative probes

All three run actual selected native tests under the shared Xcode lock, use
`-collect-test-diagnostics never`, and fail at product assertions with exit 65:

1. Bypass relay admission: the close regression detects foreign source installation,
   revision/dirty changes and retained close (5 assertion failures).
2. Restore a root-move/child key collision: the revocation regression detects a live
   grant, missing invalidation and missing reselection (5 assertion failures).
3. Bypass the post-close candidate guard: the staging regression detects the stale
   replacement and loss of original editor ownership (6 assertion failures).

Only isolated-worktree source was mutated. Every file was restored byte-for-byte;
the passing native source manifest was reverified and Git was clean afterward.
`negative/*/probe.json.gz` records exact mutations, commands, original/restored
digests and failure lines; complete logs and actual named results are retained.

## Evidence and remaining gates

`summary.json`, `main-m0-receipt.json` and `checksums.json` bind this packet.
`native/*.gz`, `m0/*.gz` and `negative/*/*.gz` retain complete logs/manifests/results.
Raw xcresults and the unsigned IPA remain at the paths recorded in the receipts,
under `/private/tmp/plainsong-pr221-fix-evidence` and `/private/tmp/plainsong-pr221-fix-20261026/Prototypes/iOSM0/Artifacts`.
The canonical [M0 receipt](../m0/results.md) selects this fresh prototype IPA;
earlier receipts are preserved under `historical-m0/`.

Exact publication-head CI is a separate GitHub check. No local macOS full suite or
XCUITest was run for this iOS-only change. Owner physical-device/signing/Files/iCloud,
IME, background, performance, accessibility and Claude/maintainer acceptance remain
OPEN. No merge or force-push; owner checkout preserved.
