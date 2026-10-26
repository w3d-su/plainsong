# PR #221 retained-close and rollback repairs

Implementation: `ec8eb5c50c7a8ec3524ee9372ea677dbfd29bfe1`. Integrated main:
`282a798da29c0a8950999a6ca297ca334f2edeb4`. Publication after this implementation
adds evidence only; all tested native and prototype input hashes are verified.

## Resulting behavior

- A user-requested conflict Reload held during close resumes once after the
  writer is retained, subject to live operation/revision/grant/lifecycle admission.
  A newer provider loss or current-token read failure retires both published and
  still-reading proposals before recovery awaits.
- M0 rollback compares the reopened original with its saved baseline by exact
  UTF-8 bytes. Changed originals retain the editor identity/source/selection/Undo
  and grant under a conflict/write fence. Failed recovery remains visibly failed.
- Latest main's Recent and Save a Copy integration is preserved. Both conflict
  sides' instructions/test names remain, with 244 unique required native names.
  Moving existing Recent methods into the existing extension resolves the merged
  class-length lint error without changing behavior.

## Complete source-bound validation

- Official `make ios-test`: **611/611**, zero failures/skips, **244 required names**,
  six compiled images, resource parity, **828 native inputs**, normal exit 0.
  Source fingerprint: `5a58754222054404671746a8c43263b5b2e07b1ca4df9cb11ecedfe7cfe1d611`.
- Official M0 runner: **38/38**, zero failures/skips, all names independently checked,
  normal exit 0. Fresh unsigned IPA: `575c957457f4f7a148a87b9fd21fd69fe421df6e68f414f5d91aedeec32b9e55`. Test and IPA share
  **24 prototype input hashes**; ZIP/fixture/arm64/iPhoneOS/iOS26/iPhone+iPad/unsigned checks pass.
- Restoring the reviewed old product source while retaining each new regression
  yields native exit **65** at the expected assertions for both Reload and rollback.
  Complete failure logs/results, mutation commands and original/restored hashes
  are retained under `negative/`. Sources restore byte-for-byte; subsequent
  selected native **6/6** and M0 **3/3** pass on restored source.
- Tooling **44/44**, packager **3/3**, pinned SwiftFormat 0.62.1 and final SwiftLint
  (zero serious violations) pass. The initial unchanged tooling run had one
  admission-fixture failure; its complete log and the successful unchanged rerun
  are both retained. The merged class-length lint failure is also retained.

Earlier source-bound native passes **536/536** (before main integration) and
**611/611** (before the method relocation) remain under `historical-native/`.
Their raw xcresults and final raw results/IPA remain at paths in `summary.json`
and `main-m0-receipt.json`; no failed run was deleted.

## Review and open gates

Independent source review verified the reload invalidation routes, exact-byte M0
fence, recovery-failure visibility and semantic access/Recent merge. Frozen C0
declarations and dependency pins are unchanged by the repair commits. The owner
checkout's preexisting `CLAUDE.md` and `.omc/` work remains untouched.

Exact publication-head GitHub CI is checked separately after push. No local
XCUITest or macOS full suite ran. Physical-device/signing/install/Files/iCloud,
real IME, background, performance, accessibility and Claude/maintainer acceptance
remain OPEN. No force-push or PR merge.
