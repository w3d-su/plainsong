# M0 result — OPEN, production composition prohibited

Date: 2026-10-08 (Asia/Taipei). Branch `phase3-ios-m0-device-spike`.
Dedicated checkout `/private/tmp/plainsong-ios-m0-device-spike`.
Base ref `phase3-ios-parallel-handoffs`, SHA
`2144c46c888360c84a42fef79e676e60b518048b`, verified against remote on this date.
This is the coordinator's pre-C0 specification base, not an implemented C0.
Contract semantics: IOS-C0-v1. No frozen declarations or production providers
are imported, replaced or modified. Code/verified artifact provenance is in
`runs.json` and per-attempt manifests; the final evidence commit changes docs only.

Draft PR: [#156](https://github.com/w3d-su/plainsong/pull/156), stacked on
specification PR #153 while its base remains open. Verified implementation SHA
`a12de4502941aed964dee42533bf39d775c2b6a9`; clean-source final checks ran
2026-10-08 10:01:18–10:01:42 UTC (18:01:18–18:01:42 Asia/Taipei), under one
shared lock. Xcode 27.0 build 27A5194q, iPhoneOS/iPhoneSimulator SDK 27.0.
The subsequent commit adds evidence only, so compiled input hashes match its
source tree. No owner device model/OS exists for this run; those fields are OPEN.

Final unsigned IPA (ignored local artifact):
`Prototypes/iOSM0/Artifacts/20261008T100133Z-ipa-1B1C5DD3/PlainsongIOSM0-unsigned.ipa`.
SHA-256 `d09502242053f56dfac1bdaefb4ba886b982c1c630bed72280ba4bbac6c9bab4`.
Fixture SHA-256 and complete compiled input hashes are in `runs.json`.
`ipa-receipt.json` records structural validation only, never installation PASS.
No device screenshots/recordings or signing materials were created.

All authored changes are in `Prototypes/iOSM0/**` and
`docs/ios/evidence/m0/**`. No root project/Makefile/CI, packages, App/AppIOS,
handoffs, shared contracts or owner checkout changes. Generated projects,
DerivedData, test bundles and unsigned IPA remain under ignored prototype
artifacts. No added package dependencies or formal target bootstrap.

| Evidence tier | Result | What it proves |
|---|---|---|
| Host Foundation core | PASS, 10 checks | Captured save baseline, one writer, failed/stale acknowledgement, conflict/unavailable refusal, exact Unicode dirty state, recovery readback/failure. |
| Negative mutation | PASS when each intentional defect is detected | Old-save-live-baseline mutation and Unicode canonical-equality mutation fail at their named invariant. Originals unchanged. |
| Generic simulator build-for-testing | Compilation PASS | App and hosted XCTest compile for arm64/x86_64 with iOS Simulator 27 SDK, deployment target 26. |
| Simulator XCTest execution | OPEN / NOT RUN | Live inventory has no installed runtime or simulator devices. Programmatic marked-text, native Undo, real UIDocument and grant XCTest must still execute. |
| Release unsigned IPA | Build/structure PASS | arm64, minimum 26, family 1+2, unsigned, no provisioning profile, Payload structure and ZIP integrity checked. |
| iPhone/iPad owner run | OPEN / NOT RUN | No supplied owner device recordings, real candidate input, Files/iCloud, lifecycle or signing/install evidence. |
| Performance/minimum OS | OPEN / NOT MEASURED | SDK 27 compile does not prove iOS 26 runtime or typing latency; no idle/frame/large-file measurements. |

| M0 gate | Status | Remaining acceptance |
|---|---|---|
| M0-IME | OPEN owner | iPhone+iPad real Zhuyin/Pinyin candidate lifecycle, editing/selection/emoji/paste and complete Undo/Redo source results. |
| M0-Presentation | OPEN owner + simulator runtime | Device switches/resizes/view changes and delayed callback rejection without extra edit, relocation or Undo. |
| M0-Files | OPEN owner | Real local/iCloud single-file and folder scope, downloads, recent restoration, offline/read-only/revoked/moved/deleted resources. |
| M0-Save | OPEN owner + simulator runtime | Actual UIDocument/file-provider write hook and conflict behavior; delayed N/N+1, background expiry/termination and recovery readback on devices. |
| M0-Install | OPEN owner | Owner re-sign exact IPA, install/launch on both devices, real Files open/edit/save/reopen. |

Meaningful failure cases and implementation fences:

- If save N is acknowledged after N+1, assigning live source to saved baseline
  clears dirty incorrectly. The immutable capture advances only savedSource;
  one active operation and exact acknowledgement prevent replay.
- Swift canonical String equality treats `é` and `é` alike despite distinct
  source UTF-8/UTF-16. The byte-equality check prevents false-clean state and
  rejects presentation for different raw source.
- A save can race an external disk edit after its capture. The UIDocument
  coordinated write hook compares original bytes to saved baseline and refuses
  unreadable/missing/changed original bytes. This hook's File Provider semantics
  remain OPEN until a real device run. A changed fileURL cannot be acknowledged
  as original-location save success; live source/recovery are retained.
- A queued old document callback can arrive after switch. Callback identity
  checks refuse it; presentation also checks identity/revision/generation.
  Clean reload advances revision instead of reusing revision zero.
- `UIDocument.close` invokes autosave during switching. A clean no-write
  acknowledgement bypasses the open busy fence, while dirty/saving/composition
  open switches stay refused. A named hosted regression test covers this route.
- Recovery failure is an error, not durability. Each success means atomic write
  plus decoded source/revision readback equality; expiry/unconfirmed document
  save leaves dirty content. A composing recovery is labeled as a draft.

Initial compile failures were selector ambiguity and MainActor callback typing;
intermediate generic builds also had cross-isolation diagnostics. They are
preserved as separate attempts in `runs.json`/local artifact directories. The
final callback relay explicitly isolates UI callbacks to MainActor and locks
immutable document bytes across file queues; no guards were disabled. Successful
final builds are not a claim that the unexecuted UIKit runtime tests pass.

Hosted named tests are in `EditorTests`, `SaveTests`, `DocumentTests`; see
`runs.json` for the exact names. They cover TextKit2, marked-text refusal, stale
presentation, native Undo round trip, same-identity reload revision, N/N+1,
failure/stale/serialized saves, Unicode bytes, recovery, real UIDocument save/
reopen/external bytes, clean close/switch, single-file confinement and symlinks.

Claude/reviewer reproduction: use the commands in the prototype README, then
the [owner checklist](manual-checklist.md). Every attempt writes its own manifest
with source SHA and file fingerprints. `build-tests` is not `test`. The native
test suite must run with an actual simulator UDID; owner test results use a copy
of the OPEN JSON template, not an edited PASS placeholder.

Pinned SwiftFormat 0.62.1 scoped lint, shell syntax, Python syntax, JSON parsing,
allowlist and `git diff --check` are checked. Root `make test`, Mac suites,
formal AppIOS CI, performance and real-device signing are not run for this
isolated lane. Review/hosted CI never substitutes for M0 owner proof.
Only the optional AppIntents metadata extraction warning remains in the final
build logs; there are no Swift compiler concurrency/deprecation diagnostics.
The lock-busy exits are scheduling waits, not failed product tests, and are
recorded separately from the earlier compile failures.

Integration handoff: retain all five M0 gates OPEN and block production
composition. Independent module/double work may continue per the shared README.
No C0 contract revision is proposed from unexecuted provider behavior. If owner
run finds loss/composition/selection/Undo/authority failure, mark FAIL, preserve
the causal evidence and submit the required contract change to lane 13.
