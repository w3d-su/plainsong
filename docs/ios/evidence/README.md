# iOS evidence: current gates and historical archive

The working tree keeps reviewable receipts, current test inputs and owner checklists.
Historical generated output is preserved byte for byte at commit
[`e20162e5c2402800e84cf1f68ae4787535228c50`](https://github.com/w3d-su/plainsong/tree/e20162e5c2402800e84cf1f68ae4787535228c50/docs/ios/evidence),
retained by tag **`ios-phase-a-evidence-20261022`**. This is an evidence archive, not a release tag.

[archived-files.sha256](archived-files.sha256) lists all **228** moved files
with their original repository-relative paths and SHA-256 digests. It covers full
source manifests, result trees, logs, probe sources, old build-script drafts and
their original inventories. Summaries are not substitutes for those bytes.

## Kept in the working tree

| Material | Why it stays |
|---|---|
| [Latest phase-A integration receipts](main-integration-20261021/README.md) | Complete 755-input native source manifest, named gates, controls and original integrity inventory remain together. Native execution is still bound to `318be8d`, not later review fixes. |
| [Parser baseline](lane-02/pre-move-baseline.json) | Executable input for both SyntaxKit differential tests and Mac EditorKit tests; unchanged bytes. |
| [Component names](validation/required-component-tests.txt) / [hosted smoke names](validation/required-hosted-smoke.txt) | Public runner admission inputs; unchanged bytes. |
| Human receipts and [frozen-contract inventory](lane-13/frozen-contracts.json) | Historical results, failures, source boundaries and architecture decisions stay reviewable. |
| [M0 checklist](m0/manual-checklist.md), results and owner template | Physical device, IME/Undo, Files/iCloud, background save and owner-install gates remain open. |

The two remaining gzip files are the latest integration's Mac control source
manifests. All **60 historical gzip files** moved to the archive. Existing human
receipts retain their original chronology; a historical PASS or FAIL is not a
claim about today's source.

## Restore and verify

From a checkout of this repository, restore into a **new temporary directory**.
The full tree is used because historical replay scripts may read files outside
`docs/ios/evidence`. This does not overwrite the active checkout.

```sh
(
set -eu
archive_manifest="$(pwd)/docs/ios/evidence/archived-files.sha256"
git fetch origin refs/tags/ios-phase-a-evidence-20261022:refs/tags/ios-phase-a-evidence-20261022
test "$(git rev-parse 'refs/tags/ios-phase-a-evidence-20261022^{commit}')" = e20162e5c2402800e84cf1f68ae4787535228c50
evidence_checkout="$(mktemp -d /private/tmp/plainsong-ios-evidence.XXXXXX)"
git archive --output="$evidence_checkout/source.tar" e20162e5c2402800e84cf1f68ae4787535228c50
tar -xf "$evidence_checkout/source.tar" -C "$evidence_checkout"
(cd "$evidence_checkout" && shasum -a 256 -c "$archive_manifest")
)
```

The fetch/test/archive/verification commands must all succeed before using the
restored evidence. Fetch the tag explicitly in shallow clones. The archive retains
the original per-run source SHAs, missing-proof notes, failed runs and checksum
files; none are reissued as current-head evidence. A `git archive` extraction has
no `.git` directory: commands that require Git state should instead use a separate
detached worktree at the pinned commit. Complete xcresults that were local-only
remain local-only; this archive does not invent or recover missing artifacts.

This reduces the PR diff and current checkout size. It does not rewrite repository
history or reduce the contents of full clones that fetch the archive tag. Keep the
tag when retiring old feature branches.

## Cleanup verification — 2026-10-22

All 228 archived files were restored from the pinned commit and matched the index.
All 18 retained non-Markdown originals remained byte-identical, including all 10
entries in the integration checksum inventory. No archived path is an executable
consumer input or one of the 755 retained native input records. Local checks passed:
iOS tooling **44/44**, acceptance components **29/29**, zero skips. These checks
validate the cleanup and component gate; they do not replace simulator/device gates.
