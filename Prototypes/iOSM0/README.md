# Plainsong iOS M0 device spike

Independent UIKit prototype for IOS-C0-v1 semantics; minimum iOS/iPadOS 26,
iPhone and iPad. No package dependencies and no production target wiring.
**M0 is OPEN. Compiling or producing an unsigned IPA does not close a device gate.**

From a clean checkout with Xcode, XcodeGen and Python 3:

```sh
cd Prototypes/iOSM0
Scripts/run.sh inventory
Scripts/run.sh core
Scripts/run.sh mutation
Scripts/run.sh build-tests
Scripts/run.sh test <simulator-UDID>
Scripts/run.sh ipa
```

Use an actual simulator UDID from your local `xcrun simctl list` (inventory raw
data is private). `build-tests` compiles app and hosted XCTest for generic iOS
Simulator; it never claims tests ran. All commands acquire
`PLAINSONG_XCODEBUILD_LOCK=/private/tmp/plainsong-xcodebuild-test.lock` before
generation, builds or runs. Busy lock yields scheduling wait; rerun later.
Do not wrap this entry point in another holder of the same lock.
Generated project/Info.plist, DerivedData, IPA and xcresult stay ignored under
this prototype. Each attempt has a distinct directory, manifest and log.
The manifest records exact Git HEAD, dirty flag, every prototype file SHA-256,
fixture SHA, Xcode version, timestamps and exit code. Retain failed attempts.

`launch <simulator-UDID> <built-app-path>` installs and launches a prebuilt
simulator app under the lock. It does not boot a simulator implicitly. Owner
device execution and signing are manual; see the evidence checklist. Use the
same lock for owner device work on this Mac. Signing identities, profiles,
accounts and device IDs must stay outside the repository and logs.

The prototype has these controls:

- **Fixture** creates a uniquely named app-private copy of the public fixture;
  **File** and **Folder** use the real open-in-place Files picker. **Recent**
  resolves one app-private `.minimalBookmark` and refuses stale/denied grants.
  Folder view lists top-level Markdown files, excluding symlinks. Single-file
  access has no sibling enumeration or assets capability.
- **Delay** enables a three-second presentation/save delay. Type N, press Save,
  then type N+1. Save captures N immediately; its acknowledgement changes only
  the durable baseline. N+1 stays dirty. Press Save again to persist N+1.
- **Undo/Redo** use the native editor UndoManager and refuse during composition.
  **Inspect** shows exact UTF-16 units, selection and source digest. The status
  and exported event log include actual marked range, revision, dirty/saving/
  conflict and Undo availability. Exported logs omit source, URLs and bookmarks.
  Native `setMarkedText`, `unmarkText`, insertion and deletion are also sampled
  immediately after their UIKit calls, alongside delegate changes/selections.
- **View switch** presents a read-only source pane. It is a presentation
  lifecycle probe, not the product Markdown preview. Dismiss by swiping down.
  **External probe** invokes the same guarded revert route without changing
  disk; actual provider edits must be exercised separately through Files.
- **Recovery** reads back persisted app-private source snapshots, including
  composition drafts. **Save copy** writes a new local file, verifies its bytes
  and opens the system share sheet. It does not overwrite the conflicted file
  or clear its dirty state. Recovery snapshots remain readable after relaunch;
  this spike deliberately has no automatic restore-to-original-file action.
- **Export log** shares redacted JSON for the public fixture. Add the owner
  result envelope with model/OS, source SHA, timestamps and expected/actual
  source/selection. Do not publish private file screenshots.

`SourceEditor` uses `UITextView(usingTextLayoutManager: true)` and TextKit 2
rendering attributes. The minimal heading pattern only probes presentation;
it is not a substitute parser or package provider. Work may return after a
document/revision/generation change, and every application rechecks all three,
source equality and marked text synchronously. Actual Undo round trips are
included in hosted tests; Boolean Undo availability alone is insufficient.
Source equality uses exact UTF-8 bytes, including canonically equivalent but
distinct Unicode encodings. Clean reload advances the same document revision.
The Foundation negative probes deliberately replace the captured saved baseline
with live source and replace byte equality with canonical String equality;
both must fail at the corresponding invariant.

`SpikeDocument` is the only file writer and uses UIDocument's coordinated
safe-write path. UTF-8 captures are immutable and locked across file queues.
Automatic saves route through the same session writer. One active save per
session/resource is allowed; another request returns failure/busy. Opening
another document is refused while dirty, composing, reloading or saving.
At the write hook original bytes must match the captured saved baseline;
unreadable/missing/externally changed bytes cause failure. Provider behavior of
this hook remains a real-device gate. Clean reload has final identity/revision/
composition checks; dirty reload records recovery and blocks overwriting.

Recovery is an atomic app-private write followed by decoding and equality
verification. It contains source, document identity, revision, reason and time.
It stores no external URL or bookmark. It is intentionally synchronous for
small public fixtures; typing latency, large files and production recovery
queues are **unmeasured**. Background flush is best effort with a finite
UIApplication background task; expiry leaves completion unconfirmed, never PASS.
The fixture workflow does not require an iCloud entitlement: Files iCloud Drive
selection uses the File Provider's grant; private ubiquity containers are outside
scope. Actual grant lifetime, downloads and read-only behavior require devices.

See [manual checklist](../../docs/ios/evidence/m0/manual-checklist.md),
[results](../../docs/ios/evidence/m0/results.md) and
[API sources](../../docs/ios/evidence/m0/api-sources.md).
