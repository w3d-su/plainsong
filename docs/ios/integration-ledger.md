# iOS Integration Ledger

Created 2026-10-08. Contract: **IOS-C0-v1 declarations implemented**. Live main: `b13aa620c7444f2ccd3a8fe3a5b8b0afe0e997b2`; specification ancestor #153: `2144c46c888360c84a42fef79e676e60b518048b`.

C0 provides declarations and an unavailable app scaffold. **C0 overall acceptance remains OPEN because simulator smoke has not executed. Production composition is blocked by M0 + real providers.**

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
