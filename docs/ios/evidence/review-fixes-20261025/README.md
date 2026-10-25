# Review dispositions for the iOS production stack

This responds to `pr-review-210-218.md`, covering #210 → #211 → #217 → #218. It separates concrete source repairs, deliberate safety behavior, and remaining work. The fixes are propagated through the stack; applicable changes must be verified in the cumulative head before its source review is closed.

**Execution evidence is recorded separately.** This source-disposition document certifies no native pass, exact-head CI pass, IPA validation, code approval, merge, or device acceptance. Consult the source-bound execution receipts linked from the PR descriptions and delivery package for actual results. Historical receipts retain their original source identities and outcomes.

## Required findings

| Finding | Source disposition | Verification and limits |
|---|---|---|
| **H1 — duplicate Recent rows with unknown production identity** | Match same-scope Recent metadata using an available provider identity or the selected/resolved URL's literal UTF-8 path bytes. Preserve a matching row's ID and remove duplicate matches. The private path field supports backward-compatible storage; legacy rows compare through bookmark resolution. A stored path/display name never authorizes access. | Add production-identity-port cases with `nil` identity, repeated files/folders, distinct scopes/paths, store round-trip, legacy rows and literal Unicode spellings. Keep #218's in-flight restore record-ID/cancellation fencing when merging the metadata fix. Every actual open still requires bookmark resolution or user selection, scope admission and a live grant. |
| **H2 — destination folders enter Recent** | Add concrete `IOSWorkspaceAccessService.openDestinationFolder(selectedURL:)`: directory-only admission without remembering Recent. Recovery and Copy use the existing access service through this API; normal open/restore defaults remain. | Verify no insertion, refresh of an unavailable row, or eviction by a transient destination. Normal lease drain/invalidation remains. The frozen access protocol is unchanged. |
| **H3 — dirty unavailable document has no useful Choose Again exit** | Offer Save a Copy for a retained unavailable document, capturing the installed source/state and validating it across suspension. Use a fresh explicitly selected destination folder and independent live lease. Do not revive the original grant or weaken Choose Again's safe-close refusal. | Cover unavailable/revoked-origin copy, cancellation, source changes, destination revocation and retained source/Undo. This preserves bytes in a new file; it does not retire an unsafe-to-close writer. Feedback explains that restarting may be needed before opening the copy to continue editing. |
| **H4 — late Recovery create failure closes the old document/folder** | Distinguish failure after safe closure/adoption from an early refusal. Late-failure feedback explicitly says the previous document was safely closed and its folder is no longer open, that restore did not overwrite the previous file/remove the draft, and how to reopen through Open or retry another folder. | Cover provider create failure after an existing document/folder and its specific feedback. Do not claim automatic rollback or silently reopen with stale authority. Early refusals preserve the installed document; provider-returned writers remain retained. Automatic old-UI/grant restoration is outside this batch. |
| **H5 — readiness retry affects Mac and hangs with nil navigation** | Disable silent-initial-load retry by default on macOS and keep the Mac completion path independent of the iOS navigation fence. On iOS retry with no navigation object, a matching ready signal starts a current-page readiness probe fenced by page generation. | Add platform-default, nil-navigation, stale-probe and reentrant/duplicate callback checks. Do not blindly accept queued old-page ready, await an impossible matching callback, or relax protocol/CSP/network/export/readiness assertions. This does not establish Mac cold-start/performance acceptance. |

## Other review observations

### #210 — lifecycle and feedback

- **Transition polling:** bound shutdown's transition wait to two seconds by default. Expiry/cancellation returns unsuccessful shutdown while retaining provider/writer admission, observers and state so work can drain safely. This bounds that polling phase; it is not a two-second guarantee for all later provider flush/close operations. A shorter test seam does not change the production default.
- **Clean document retained on an external change:** keep conservative close refusal. Clean text can coexist with an unresolved provider/external-change operation. Replace misleading unsaved-change instructions with feedback that the document remains open because its provider or an external change prevented safe close.
- **Enum spellings in alerts:** route shell/production failures through shared user-facing feedback. Known save/close/access/provider failures receive actionable copy; unknown errors receive generic operation feedback. Preserve diagnostic errors without using their raw enum spelling as UI text.
- **Process-wide admission:** retain it intentionally for the single-scene product. A recreated runtime must not open another writer while a discarded scene still owns one. Retained admission can block opens until safe retirement or app restart; record that limitation and recovery/restart path. Never force-release it for apparent availability.

### #211 — Recovery presentation

- **Filename/repeat collision:** use the old leaf's display stem, `Recovered`, and a fresh short suffix per restore issuance, retaining Markdown/MDX type selection. This suggestion grants no path authority. Create-new still refuses existing leaves and provider races; randomness is not overwrite protection.
- **Ordering/time:** sort by literal filename, then descending revision version; record ID only breaks ties. The record has no reliable creation timestamp, so do not invent dates or call this chronological sorting. Compatible timestamp persistence/display is an explicit follow-up.
- **Bottom entry strip:** move Recovered Drafts into Files toolbar chrome rather than reserving a row below the editor. Preserve its labelled reachable entry and minimum target size. Physical layout/accessibility checks remain open.
- **Premature navigation:** track the sheet issuance and actual appearance. Consume restored navigation once from that issuance's actual `onDismiss`; stale/duplicate callbacks, cancellation and a sheet that never appeared cannot navigate. A binding change alone does not prove dismissal.

### #217 — Copy and composing Reload

- **Physical Chinese IME:** retain the transition fence and existing native relay's deferred Reload. Synthetic marked-text coverage is a regression check, not physical acceptance. Owner checks must hold an active Zhuyin/Pinyin candidate, request Reload, and inspect committed text, selection, Undo/Redo and save/reopen after composition ends. Keep this gate open until observed on a physical device.
- **Conflict after successful copy:** retain deliberately. Copy creates a new leaf; it does not resolve the original conflict or replace editor text. Success feedback explains this and says Reload replaces the editor text with the current disk version. Unavailable-source success separately describes retained state and the restart/open-copy path.

### #218 — Recent cancellation and folders

- **Cancellation after a provider returns a writer:** retain that writer/session and admission, invalidate the abandoned grant, and keep it read only until safe close. Never discard it or reauthorize stale completion. Generic access-change feedback can still be confusing for this race. A dedicated cancelled-open explanation and safe-close/restart path remain an explicit UX follow-up. This batch does not claim cancellation always restores the old screen.
- **Recent folder closes the current document:** retain the same workspace-replacement behavior as an explicit folder picker. Safe close must succeed before installation; a refusal retains current source/session. This does not create a concurrent workspace.

## Governance and evidence

| Observation | Disposition |
|---|---|
| Branch names | The desktop task instruction specifies `codex/`, taking precedence over the repository's historical `phase<N>-` example for these branches. Preserve existing branch identities; do not rename or rewrite the stack for cosmetics. |
| Milestone commit subjects | Preserve published history. New review-fix subjects use `Phase iOS:` and explain the behavior/reason. This does not retroactively relabel older subjects. |
| Large files | Extract focused shared operation feedback/small helpers where that improves ownership without changing behavior. Broader pre-existing controller/surface partitioning remains an explicit follow-up. Do not hide warnings, raise limits, or claim every file meets the approximate guideline. Broader splits need separate diff review and validation. |
| Cross-lane work | This is the authorized integration owner's review-fix batch after lane delivery, covering composition and its concrete adapters. Record affected lanes in each PR description. Frozen C0 declarations, dependency pins and preview assets remain outside this repair's scope; adapter integration is not authorization for unrelated lane work. |
| Large JSON/local raw paths | Preserve complete case/source/artifact receipts and failures for audit. `/private/tmp` locators describe local recorded runs; they are not durable downloadable artifacts or clean-checkout reproduction. A clean checkout runs the documented commands with its own prerequisites/destination and creates new source-bound receipts. Delivery must identify copied evidence versus local-only artifacts. |
| Native results versus later heads | Never relabel an old native result to a new source SHA. Record actual execution source/cases and CI at the published head. Source changes require applicable new execution; old green results alone do not close these fixes. Keep failed/time-limited attempts. |
| Squash stack | Only the maintainer merges. After each parent squash, retarget the next child to current main, integrate main with a normal merge, inspect its net tree diff/shared test manifests, and validate the new head. No force push, published-history rewrite, destructive reset or self-merge. |

## Maintainer merge runbook

Apply separately in order: **#210 → #211 → #217 → #218**. Stop on unreviewed source/conflict/test/evidence changes. Green CI or mergeability does not constitute approval.

1. Use the level's isolated worktree. Refresh remote refs through the maintainer's normal fetch flow, then run these read-only checks. Verify clean status and compare `HEAD` with the current remote PR head before integrating parent/main changes:

   ```sh
   git status --porcelain=v1
   git rev-parse HEAD
   git branch --show-current
   git ls-remote origin refs/heads/main
   git log --oneline --left-right origin/main...HEAD
   git diff --name-status origin/main...HEAD
   git diff --stat origin/main...HEAD
   git diff --check origin/main...HEAD
   ```

2. Review #210 against current main. After the maintainer squash-merges it, retarget #211 to main and normally merge newly fetched main into #211's branch. Repeat for #217 after #211 and #218 after #217. Do not merge a child using its obsolete parent base. These are future maintainer actions; this document performs none of them.

3. Repeat the checks and inspect `git diff origin/main...HEAD` in full after every normal merge. Its tree diff must contain only the intended child behavior/integration repair. Old parent commits still listed in ancestry do not alone prove duplicate code; unexpectedly empty/broadened tree diffs require investigation. Check frozen contracts, dependency pins and preview paths against the agreed source inventory. Inspect every conflict resolution explicitly.

4. Compare shared test manifests with both the child before integration and current main. Preserve both required-case sets plus new child cases, exactly once per manifest. Never choose one shared tail wholesale. The following read-only duplicate check supplements actual method-declaration and required-set comparison:

   ```sh
   python3 - <<'PY'
   from collections import Counter
   from pathlib import Path
   manifests = [
       Path('Scripts/ios/required-named-tests.txt'),
       Path('Scripts/ios/required-preview-tests.txt'),
       Path('docs/ios/evidence/validation/required-component-tests.txt'),
       Path('docs/ios/evidence/conflict-copy-ui-20261023/required-named-tests.txt'),
       Path('docs/ios/evidence/recent-access-ui-20261023/required-tests.txt'),
   ]
   for path in manifests:
       if not path.exists():
           continue  # Child-specific manifests need not exist in their parent.
       names = [line.strip() for line in path.read_text().splitlines()
                if line.strip() and not line.lstrip().startswith('#')]
       duplicates = [name for name, count in Counter(names).items() if count != 1]
       if not names or duplicates:
           raise SystemExit(f'{path}: empty or duplicated cases: {duplicates}')
       print(f'{path}: identifiers unique within this manifest')
   PY
   ```

5. Run applicable checks at the resulting source using the existing native admission lock/runners. Inspect enabled plans, actual named-case inventories, failures/skips and source/artifact receipts. Attach exact-head CI and new native/IPA evidence at their actual scopes; documentation-only publication retains the tested source identity. Review the final full diff at that head before the maintainer decides whether to merge.

6. Preserve historical worktrees, kits and failed-run evidence needed for review reproduction. Signing/install, real Files/iCloud/provider behavior, physical IME, minimum OS, physical iPad, accessibility, keyboard and measured performance remain separate owner gates. This runbook neither approves a PR nor closes those gates.
