# Independent main-finish source review

Review scope: the complete code/test/tooling delta from main `e09801309e855dce6ee903101ac2180e164daef2` to candidate `565a7b15b47e66de9dc08d114e4dc117c033ebe1`, plus the historical decision/evidence additions from the two transplanted patches. This is source review and preservation evidence. It is not native execution, a GitHub approval, or physical-device acceptance.

## Findings and resolution

The initial exact-tree transplant `c5fc4f652205fc443321fe0463c0914720b262c7` contained the complete reviewed #217/#218 stack but inherited a reachable Recent pending-file defect. `installSingleRecent` used the available-only `documentLocation` lookup. A valid restored Markdown/MDX single-file grant whose metadata reported downloading/offline therefore threw unsupportedType; error cleanup released the grant and Files snapshot. The real metadata port requests immediately available metadata and retains its availability in `singleFileEntry`, so the failure was not confined to a test double.

The final fix reuses the existing picked-file classification and pending-selection retention helpers. It retains a downloading/offline restored selection only while the same grant and issuance remain current, and refuses retention after cancellation, supersession, shutdown, disposal or revocation. It preserves the prior matching queued-Files cancellation exception and the returned-writer safe-close/refusal path. Presenter feedback uses the existing typed operation messages. This resolves the identified source defect; the native results must independently establish execution.

Twelve newly required regressions cover pending metadata, provider failure after an available snapshot, same-grant Refresh/retry, sibling refusal, actual revocation, unsupported types, cancellation, superseding URL delivery and typed feedback. The new store-double failure capture is taken before suspension so later test configuration cannot alter an already-issued operation. Existing named tests and deadlines were retained.

No unresolved actionable source finding remained in this reviewed head. The code review does not claim that unobserved provider/device behavior has passed.

## Integration and preservation

The content proof is stronger than PR merged labels or ancestry:

- main `e0980130` and #217's squash first parent `085369fa` share tree `107e72a97d54e7b3fce9b90d82ede6b721003ff3`.
- #217 squash `b28bf336` and #218's first parent `a39e2a6c` share tree `460e655ec5e0d1e66b071de2ddb2b8fe6e2960e4`.
- #218 squash `3de75ee2`, historical stack `b1380edc`, and clean two-patch transplant `c5fc4f65` share tree `7b599c3f29e478a8cf067d4cb8575de60083e198`.
- Both transplanted commits retain their cherry-pick provenance and stable patch IDs. Candidate descends directly from main through these two additive commits. No divergent-history merge was used.

The independent script `audit-preservation.py` passed 23/23 checks for final implementation head `565a7b15b47e66de9dc08d114e4dc117c033ebe1`. Its result is `preservation-final.json`, SHA-256 `fad5b2b8ecbe7c3f4eca8c86fd12124edf49f71a538dcf6e46d56fd9aa9b11bf`.

The audit verifies the 13 frozen files against their original recorded SHA-256 hashes and scans the 71 indexed declarations for uniqueness. The one exact unchanged EditorKit compatibility typealias to `SyntaxKit.MarkdownSyntaxToken` is explicitly recognized, rather than misclassified as a second implementation. It verifies unchanged main bytes/modes for 342 Mac app paths, 536 Mac/shared-package paths, 77 preview source/dist paths, 21 dependency-pin/manifest paths, both global build entries, all three workflows, and 180 original test/tooling paths outside the reviewed feature scope. Groups overlap and are not additive file counts.

All original 125 main required names and all 187 stack required names are present; the final list contains 199. Original component and hosted-smoke names remain. Save a Copy continues to use the existing store writer and an independent destination-only create-new grant; origin/binding/revision/dirty/state/grant/lease guards remain across suspension. It does not close/replace the origin, overwrite an existing leaf, clear conflict/recovery, or treat a copy receipt as an original-save acknowledgement. Recent continues to use opaque record IDs and the same access service, preserving safe-close/refused-writer retention, latest-pending navigation and cancellation fencing.

Owner checkout HEAD, branch, status and CLAUDE.md SHA-256 exactly match `owner-checkout-before.json`. No native commands or worktree source writes were performed by this reviewer.

## Source binding and evidence limits

The final clean candidate has 810 captured iOS source/build/test inputs and fingerprint `3ac1cda78e689a2608c262edd0e766e12887f84fa9914405fed2f2ebad758218`. This differs from historical stack fingerprint `d4977783ddc507793d0ff7ed2a2d24ab1cadb9e16adc2b6fd951ccf2c5c48f78`; historical native results cannot be relabelled to the fixed source. The exact native execution SHA, CI head and actual delivered IPA must be recorded independently.

The first audit attempt is preserved in `preservation-b27c231.json` with `audit-preservation-v1.py`; it reported the existing compatibility typealias as a declaration false positive. The corrected audit's draft rerun `preservation-b27c231-v2.json` failed only its clean-worktree condition because the authorized product fix had started concurrently. Its dirty fingerprint is not a clean tests-only source proof. The final clean implementation audit above passed without those conditions.

Owner signing/install, physical iCloud/Files, device Chinese IME/Undo, iPad/minimum OS26, VoiceOver/external keyboard and measured performance remain separate gates. Source review and structural delivery checks do not close them.
