# iOS Integration Ledger

Created 2026-10-08. Contract: **IOS-C0-v1 declarations implemented**. Live main: `b13aa620c7444f2ccd3a8fe3a5b8b0afe0e997b2`; specification ancestor #153: `2144c46c888360c84a42fef79e676e60b518048b`.

C0 provides declarations and an unavailable app scaffold. **Current phase A source integration is in progress; full v1 acceptance remains OPEN. See the dated current section below. Production composition is blocked by M0 + real providers.**

## Main integration candidate — 2026-10-21

This section supersedes the older readiness snapshots below. They remain historical
receipts. The candidate merges main `15913f882b4994280f239fc90ee5f8d52d5f043b`
with #164 `fdd2a071c04f61f5259d31cf17699534d77fce9e` and the reviewed #187
follow-up. No GitHub PR is merged by the agent.

- #174, #172, #176, #173 and #175 are incorporated in the review aggregate.
- #155 and #158–#163 are closed as superseded; every original head remains an ancestor.
- #153, #156 and #157 source is retained. Their original PR state is not proof of
  main inclusion or M0 acceptance.
- STTextView 2.4.1 and main's editor/preview fixes remain. The prepared-coverage
  parser entry moves to SyntaxKit; native writer/selection/Undo/IME rules do not change.
- Eleven incoming decisions now have their own files in `docs/decisions/`; main's
  historical Decision Log archive is unchanged.
- Production composition stays unavailable, and `AcceptanceDebugSeam` stays disabled.

Current aggregate Mac CI at `fdd2a071` passed [39533452831](https://github.com/w3d-su/plainsong/actions/runs/39533452831).
That run does not execute UIKit tests and is not the main-integration candidate's CI.
The combined candidate's local/native and exact-head CI gates are **PENDING** until
recorded in `evidence/main-integration-20261021/README.md`.

The historical app-hosted preview 94/94, modules 300/300 and lane 06 107/107
remain source-specific evidence. The #187 diagnostics retain eight complete
results and a source-bound 94-case pass, but do not prove platform causality for
all old failures. See its corrected observations packet.

M0 physical iPhone/iPad, iOS 26 runtime, Traditional Chinese IME/Undo,
Files/iCloud/offline/conflict/background persistence, owner re-sign/install,
production composition, composed-app acceptance, accessibility/performance and
release IPA remain OPEN. Phase A source integration does not authorize providers.

## Phase A readiness — 2026-10-16

This is the current readiness snapshot. The 2026-10-13 review below stays the historical receipt for that aggregate. Production composition is still `IOSProductionComposition.c0`: editor, documents, workspace, preview, and assets are nil. Phase B is **OPEN**. The app entry does not call `IOSOpenDocumentAdmission` and does not install a provider.

The prompt start `59f374ff9341289b91c0a4090b216dcf16510797` is an ancestor of PR #164, not its live head. After fetch on 2026-10-16, draft PR #164 (`codex/ios-review-fixes-20261013` → `codex/ios-review-baseline-20261013`) is head `fdbcd44444f958589cb1e662d67ce3015e5e9f30` because #171 merged. This phase A branch starts there. It does not reset #164 or retarget lane PRs.

| Lane | Live branch / head | PR | Base relationship | Provider vs double | Gate |
|---|---|---|---|---|---|
| 06 Access | `codex/ios-06-workspace-access-20261015` `142e07d7b1e0a4bb693e2561d1f4e34be842ee25` | [#172](https://github.com/w3d-su/plainsong/pull/172) draft, MERGEABLE | Contains `59f374f`, not `fdbcd44`. Classic `git merge-tree` from merge-base `59f374f` reports no conflict with `fdbcd44` | One `IOSWorkspaceAccessService` implements access, coordinated I/O, asset writing, `PreviewAssetReading`, and `PreviewAssetAccessChecking`. It does not implement `IOSDocumentStore`. Factory `makeProduction` exists and is not called by the app. Scripted ports are the test double. Simulator 104/104 is that head's module run, not this head and not Files/iCloud | Module candidate. Device Files/iCloud OPEN. Do not inject until phase B |
| 07 Preview | Integrated port remains on the review branch. Ready note: `codex/ios-07-ready-repair-20261015` `460787452994ecc53b81b1e2e0a330f818424eda` | [#173](https://github.com/w3d-su/plainsong/pull/173) draft, docs only. Historical [#162](https://github.com/w3d-su/plainsong/pull/162) still targets `phase3-ios-integration` | #173 contains `59f374f`, not `fdbcd44`. Same merge-tree reports no conflict | iOS installs no reader until `installAssetReader`. Mac keeps `DirectPreviewAssetReader`. No `WorkspaceKitIOS` import | Real bundle ready FAIL. #173 does not attribute a cause. Three export failures stay unconfirmed |
| 11 Validation | Harness is on `fdbcd44` via merged #171. Receipt split `codex/ios-11-receipt-split-20261015` `767c0cff783a27cf1442cb5239031b4ea039d67c` | [#174](https://github.com/w3d-su/plainsong/pull/174) draft. #171 merged | #174 contains `fdbcd44` | `ProductGateLedger` has no `.pass`. `AcceptanceDebugSeam.releaseCanEnable()` is false. Component logs are split: 18, 26/26, and a filtered 7/7. No retained 29-case run of `6d65210` | Product, hosted UI, device, and performance OPEN |
| 12 Build | Tooling on the review branch at `6d52984` and ancestors `d4d412c`, `288f8b8`, `08084cb`. Old `phase3-ios-build-and-ipa` is `08084cbc5f23de2075ad2fef5f93850e35e83b74` and has no newer PR | No open PR for the old branch. `ios.yml` is manual dispatch | Already inside #164's history | C0 tooling IPA source `3d4f671545eb41190b1b8e7262bcd27349aad36e`, SHA-256 `138096c65c31faa674864cf6f093119d3dbc055cb26df0e86797730c238becdd` | That IPA is not an `fdbcd44` binary. Current-head unsigned IPA and owner install OPEN |
| 13 Integration | `codex/ios-13-integration-gates-20261015` from `fdbcd44` | This phase A draft, base `codex/ios-review-fixes-20261013` | — | Capabilities remain nil. `IOSOpenDocumentAdmission` refuses a second writer and is not wired | Phase B OPEN |

Frozen IOS-C0-v1 file bytes match tag `642cb212703220409874a2741c5adbfb8c80fe8a` on `fdbcd44`, `142e07d`, `4607874`, and `767c0cf` (13 files, 0 hash mismatches). No contract bump.

Dependency direction stays `WorkspaceKitIOS` → `PreviewKitContracts` and `PreviewKit` → `PreviewKitContracts`. Lane 06 does not import `PreviewKit`. One access service is the future reader injection; it is not a second access manager and it is not the document writer. Lane 05's `IOSUIDocumentStore` remains the only document-byte writer. Each lane 06 `open` mints a new workspace identity, and its production identity port returns nil. Phase B must not dedupe opens by URL, inode, or `NSURLDocumentIdentifierKey`. A second document while one ticket is active is refused by `IOSOpenDocumentAdmission`. `end` matches the ticket's issuance, not document identity alone. An older issuance cannot clear a later admission of the same document. The app still does not call this type.

Phase B start and final acceptance are different lists. Wiring may start after named M0 IME/Undo, Files/iCloud, and background-save evidence, a pre-composition owner re-sign, the lane 06 service on the candidate, and a passing lane 07 real-bundle readiness run plus its full required PreviewKit suite. Lane 07 must make the first controller ready in a real app-hosted test process, retain the bundle assertions, and keep the 8-second readiness / 2-second JavaScript limits. Recording a FAIL does not satisfy this start condition. Lane 12 owns the test-host wiring; that scaffold does not require production composition. Lane 11 product acceptance and the lane 12 IPA of the composed head come after composition. They are not start conditions. v1 stays open until those final rows pass.

`PreviewAssetReadResult.coordinatedURL` from the unmerged lane 06 reader is the logical grant `IOSFileLocation.fileURL`. The file port's proved URL stays internal because a location built from it is `.outsideGrant` under `authorize`. Symlink files are refused before bytes. Do not publish the proved URL without a contract revision.

iPhoneSimulator 27.0 SDK `NSURL.h` marks `NSURLBookmarkCreationWithSecurityScope` and `NSURLBookmarkResolutionWithSecurityScope` `API_UNAVAILABLE(ios)`. The website listing for `withSecurityScope` (Context7 `/websites/developer_apple_foundation`) is not the SDK availability. Lane 06's plain bookmark plus `startAccessingSecurityScopedResource` matches that header. Device grant lifetime stays OPEN.

Merge batches, maintainer-owned, without retargeting existing PRs: #174 docs, then #173 docs, then #172 as a module-only merge. None of those merges authorizes calling `makeProduction` or replacing `c0`. M0 rows below stay unchecked.

Local PlainsongIOS simulator run on this dirty phase A tree: public `make ios-test`, iPhone 17 Pro `59CB04BD-26CC-4841-8D06-E75A2EDEBC66`, iOS 27.0, Xcode 27.0 (27A5194q). The first build failed because `Refusal` did not conform to `Error` (runner exit 65). After that conformance, the same runner executed 299 tests, 299 passed, 0 skipped. The review fix rerun executed 300, passed 300, skipped 0, including the stale-ticket case. Neither run is the historical 294, Mac CI, or a device gate. Detail: [phase A packet](evidence/lane-13/phase-a-20261016.md).

## Review update — 2026-10-13

**Full v1 acceptance OPEN.** This dated update supersedes earlier environment/provider rows for current readiness; the historical C0 receipt below remains unchanged. Original published lane PR heads were read again and still match the audit baseline. A separate aggregate baseline `9ddd0c3cc0b3cb3439ed296400abbb701eb48886` receives the review fixes; original branches and PR bases are preserved.

- Fixes for 03/05/07/08/09/10/12 are integrated; all 13 frozen hashes match. The public runner at c1 actually executed 294 unique cases, all Passed with zero skips. The original 17 cases and C0 smoke 12 passed. MarkdownCore had 322 compiled symbols but only 2 selected iOS cases.
- Six native storage guard removals each caused one named assertion failure with zero skips. Every one of the 148 inputs restored after each mutation; the final module ran 46 Passed cases. All 117 storage dependency inputs equal the aggregate. Full 148-input equality is only 138 because full PreviewKit is outside this scheme's dependency graph.
- Full PreviewKit-Package native execution was 94 cases: 90 Passed, 4 Failed, zero skips. The old product scheme had no test bundle and the old 46-case inventory was incorrect; both attempts are retained. A proven fixture alias defect is corrected in one test file, but the subsequent targeted 2-case run still had one pass and one failure: real bundle readiness timed out. The preview gate is FAIL; three Export failures remain unconfirmed.
- Mac PreviewKit 94, architecture 5, WorkspaceCore 29, tooling 21 and portable 149 source-bound passes are retained. C1 Mac CI passed WorkspaceKit 362/focused 69, then failed the manual sandbox link because WorkspaceCore objects were missing. The one-line wiring fix passed local 69 and the actual signed sandbox probe. Updated exact-head CI is separate.
- Lane 06 has no real Access/Workspace implementations; lane 11 lacks the acceptance harness/target; lane 13 capabilities are nil and its entry point is C0. M0 devices, real Files/iCloud, background, IPA installation, accessibility and performance remain OPEN.
- The owner authorized the shared CoreSimulator service reset, after which discovery worked. No unrelated xctest was directly signalled and no shutdown-all was used. All heavy work used the canonical lock. Old blocked attempts are retained; the reset does not establish their historical root cause.

[Review receipt and next-agent handoff](evidence/review-20261013/README.md) records current completion evidence, immutable source scopes and all failed attempts. The C0 receipts below are historical. Lane 12's tooling IPA is not a functional v1 or this aggregate's final-head binary. Claude review and maintainer merge remain pending; exact current-head CI is reported in the delivery packet.

## Shared implementation baseline

| Field | Value |
|---|---|
| Integration branch | `phase3-ios-integration` |
| PR base | `main`; includes the authorized #153 packet as an ancestor |
| C0 PR / freeze head | [#157](https://github.com/w3d-su/plainsong/pull/157) (draft); code freeze `642cb212703220409874a2741c5adbfb8c80fe8a`; latest PR head tracked by GitHub |
| IOS_BASE_REF | `refs/tags/ios-c0-v1` (remote ls-remote verified) |
| IOS_BASE_SHA | `642cb212703220409874a2741c5adbfb8c80fe8a` |
| Declarations | 13 frozen files / 71 unique declarations; frozen-contracts.json |
| App / tests / scheme | `PlainsongIOS` / `PlainsongIOSTests` / `PlainsongIOS` |
| Contract smoke | 12 selected cases compiled; execution OPEN, no runtime/devices installed |
| Global manifest transfer | Transferred exclusively to 12 by this additive documentation receipt after #157 creation; freeze tree `642cb212703220409874a2741c5adbfb8c80fe8a` |
| Production composition | All capabilities nil; no provider factory, fake data or saved-success state |

The immutable tag points to the code freeze; a later documentation-only receipt records its full SHA without attempting a self-referential commit hash. Other lanes read that receipt before starting implementation and must fetch/verify the exact tag. A later integration branch head is not an interchangeable base.

## Local evidence

| Scope | Result | Evidence |
|---|---|---|
| Mac `make test` and `make build` | PASS | MarkdownCore 322; EditorKit 454 (7 opt-in skips); PreviewKit 71; WorkspaceKit 357; sandbox root subset 67; App 801 (5 skips); UI 29; Performance 30 (4 skips); F2 tooling 86; JS 127 |
| New portable core checks | PASS | SyntaxKit 1; WorkspaceCore 1; restored-positive identity/baseline 2 and architecture 5 |
| iOS generic simulator build-for-testing | PASS | App + all package/hosted test targets, arm64/x86_64; Xcode 27.0 (27A5194q), Simulator SDK 27.0, minimum 26.0 |
| iOS test execution | OPEN | `simctl list runtimes/devices` empty; compiled cases are not executed PASS |
| Preview resources | PASS | Every bundled file SHA-256 equals the committed Mac preview; bootstrap records the manifest |
| SwiftFormat 0.62.1 / SwiftLint / diff | PASS | Pinned lint, zero serious lint violations; original Mac target blocks and third-party pins retained |
| Negative mutations | PASS (expected failures detected) | Ignoring document identity, acknowledging old source via markSaved, and linking full PreviewKit each fail the named assertion; source restored |

This full Mac run used `CI=1` for timing classification. It is regression evidence, not owner idle/performance acceptance. Named tests, commands, failed attempts and local artifact locators are in [C0 verification](evidence/lane-13/c0-verification.md).

## Exact-head hosted evidence

The publication receipt precedes the final PR-head hosted result; no unverified success is recorded here. The draft PR's `CI / build-and-test` must be read for its current full head; prior heads/reruns do not substitute. iOS hosted execution remains OPEN until 12 supplies a usable manual workflow/runtime. CodeQL is informational.

## Lane receipts and exclusive transfer map

| Lane | Receipt / starting point | Provider status | Unique ownership after transfer | Open gates |
|---|---|---|---|---|
| 01 M0 | [#156](https://github.com/w3d-su/plainsong/pull/156), `d7d1902f97e6d2ca8cb86cd5ea218d6e8464d44b`; packet-based separate prototype | Prototype receipt only; device evidence not accepted | Prototypes/iOSM0; evidence/m0 | All M0 owner gates |
| 02 SyntaxKit | Adopt verified IOS_BASE_SHA; no implementation receipt accepted | Token declarations only; parser/fold/grammars remain Mac | SyntaxKit + EditorKit manifests and narrow parser/fold allowlist; excludes frozen files | Differential, Mac regression, iOS provider |
| 03 WorkspaceCore | Adopt verified IOS_BASE_SHA | Portable models only | WorkspaceCore + WorkspaceKit manifests and narrow tree/path adapters; excludes Contracts.swift | Byte paths, physical sidecars, root guards |
| 04 EditorKitIOS | Adopt verified IOS_BASE_SHA | Native writer absent | Editor/Presentation/tests + EditorKitIOS manifest; excludes Contracts.swift | Guarded native Undo, actual IME, real syntax |
| 05 Document I/O | Adopt verified IOS_BASE_SHA | Store interface only | WorkspaceKitIOS Documents/Recovery + corresponding tests | Serialized UIDocument, baseline, durable recovery, real access |
| 06 Access | Adopt verified IOS_BASE_SHA | Access/coordination/asset interfaces only | WorkspaceKitIOS Access/Workspace + corresponding tests | Leases, provider reads/writes, bookmark/root guards |
| 07 Preview | Adopt verified IOS_BASE_SHA | Contract product only; UIKit port absent | PreviewKit manifest/implementation/tests; excludes frozen contracts and wire protocol | Reader/checker, late callback fences, Mac export |
| 08 Authoring | [#155](https://github.com/w3d-su/plainsong/pull/155), `f6a8ae93e0b86f9d4d881622dee8b4dda1e16eca`; research only | Registration request accepted by C0; no feature implementation receipt | Features/Authoring + AppIOSTests/Authoring | Native writer, actual Undo, IME/keyboard/VoiceOver |
| 09 Images | Adopt verified IOS_BASE_SHA | Insertion context/seam only | Features/Images + AppIOSTests/Images | Saved leaf before source; retained ownership; real writer/editor |
| 10 Shell | Adopt verified IOS_BASE_SHA | State/action capabilities only | UI/Navigation + AppIOSTests/Shell | View lifetime, command focus, real providers |
| 11 Validation | Adopt verified IOS_BASE_SHA | No final acceptance | IOSAcceptanceTests + evidence/validation | Exact integrated head, devices/accessibility/performance |
| 12 Build | Transfer now effective after #157 creation; adopt IOS_BASE_SHA | C0 bootstrap build/test only | project.yml, Makefile, Scripts/ios, ios.yml, build/IPA docs | Stable iOS entries, manual CI, device IPA, owner install |
| 13 Integration | C0 freeze + publication receipt | Production factory unavailable | Frozen declarations, MarkdownCore platform/contracts, WorkspaceKitIOS manifest, App/State/Composition/Integration tests and central docs | Runtime smoke, Claude review, M0/provider composition |

C0 architecture inventory `EditorReplaceLayeringTests.swift`, WorkspaceKitIOS Contracts tests, `.gitignore` and `.swiftlint.yml` remain 13-owned; other lanes submit proposed central changes. Syntax/WorkspaceCore/EditorKitIOS package smoke tests transfer with their module. Existing lane handoff allowlists still narrow the paths above. No shared file has two writers.

## M0 owner-only evidence

- [ ] iPhone/iPad models, OS, app/source head and fixture hashes recorded.
- [ ] Actual Traditional Chinese Zhuyin/Pinyin composition, candidate confirmation, selection and native Undo/Redo.
- [ ] Local Files and iCloud Drive file/folder in-place open/save, placeholders/offline, external changes and permission reselect.
- [ ] Background save/recovery and relaunch; older completion cannot erase newer source.
- [ ] Owner-re-signed unsigned IPA launches and opens/saves selected Files resources.

Prototype archive/build, simulator compilation, doubles, Mac tests and CI do not check these boxes. #156 explicitly reports them OPEN.

## Explicit ownership transfer — 2026-10-08

This documentation-only receipt is the transfer event after draft PR #157 exists. Frozen code/manifests are commit `642cb212703220409874a2741c5adbfb8c80fe8a` / remote `refs/tags/ios-c0-v1`. Find this receipt commit with `git log --format=%H -1 -- docs/ios/c0-baseline.md`; the PR body records its exact SHA after publication.

- 13 → 02: SyntaxKit and Mac EditorKit manifests; narrow parser/fold/token-compatibility paths remain 02, frozen token/contracts remain 13.
- 13 → 03: WorkspaceCore and Mac WorkspaceKit manifests; frozen model file remains 13.
- 13 → 04: EditorKitIOS manifest and Editor/Presentation/module tests.
- 13 → 07: PreviewKit manifest, platform implementation/tests; frozen contract/export files and wire protocol remain excluded.
- 13 → 12: root project.yml, Makefile, Scripts/ios/** and future ios.yml/build docs. 13 will review proposed global changes rather than concurrently edit those files.
- 13 retains MarkdownCore platform/contracts, WorkspaceKitIOS manifest, frozen API files, central architecture inventory, AppIOS App/State/Composition and Integration tests/docs.

The tag itself contains the freeze-stage ledger; use this publication receipt to obtain the full SHA and effective transfer. The code and frozen-file hashes are identical. No worktree is reset or modified for another lane; existing pre-C0 plans must adopt this tag with additive commits or a new isolated implementation worktree.

## Release receipt

No C0 IPA, signed device run, iOS typing/render budget, accessibility acceptance or complete app is claimed. Claude review remains pending. Maintainer merges; no self-merge or force-push.
