# CI failure evidence and resource preflight — local validation

2026-10-04, Asia/Taipei. Implementation base: `4cef0ccf44e422ad22ab34c4319a46c42e69b009`.
This change captures the next resource/CAS failure; its historical root cause remains unknown.

## Behavior

- CI prepares runner-temp paths containing run ID and attempt. Hosted tests use isolated
  DerivedData and `Results.xcresult`; the app build uses the same explicit DerivedData.
- CI first builds for testing, then hashes/inspects the built PerformanceTests resources,
  then runs tests without rebuilding. Separate build, preflight and test logs retain their
  original failure exit codes through `tee`.
- A bundled contract names the three editor/open/memory fixtures, preview HTML/JS/CSS and
  every shipped font. The manifest includes the contract itself: 67 files in this revision.
  Inspection requires regular, readable, non-empty files and records SHA-256, size and
  permissions. Read-size changes fail with EIO; missing files fail with ENOENT. One clear
  path/errno/bundle diagnostic and a partial manifest survive a preflight failure.
- Local `make test` with all three new variables unset preserves the original combined
  xcodebuild `test` action and TEST_RUNNER_CI forwarding. PerformanceBudgetTests checks
  once before timing and logs resource metadata; subsequent cases skip after its first
  preflight error. There is no retry. Runtime diagnostics stay in the captured test log,
  avoiding an extra sandbox grant to a runner-temp directory.
- Failure/cancellation uploads only the controlled evidence directory for 14 days:
  xcresult when execution created it, build/test/preflight logs, resource manifest and a
  failure-time allowlisted image/Xcode/disk/file-descriptor summary. No home/workspace
  archive, DerivedData archive or environment dump is collected. Success skips upload.
- Budgets, Xcode selection, F2 scripts, product code and owner acceptance gates are unchanged.

## Verification

| Check | Result |
|---|---|
| `make build`, new variables unset | PASS; `/private/tmp/h23-make-build.log` |
| build-for-testing with isolated DerivedData | PASS; `/private/tmp/h23-build-for-testing.log` |
| Preflight on actual built bundle | PASS, 67 entries; `/private/tmp/h23-preflight-normal.json` |
| Scratch bundle with renamed `perf-500kb.md` | PASS: exit 1, one message containing path/errno=2/bundle, retained partial manifest; `/private/tmp/h23-preflight-missing.log`. Real fixtures were untouched |
| Wrapper failure controls | PASS: unset-variable combined action and CI forwarding; build failure exit 65 stops before preflight/tests; simulated test failure exit 65 retains all three logs and a real passing bundle manifest. These are local command mocks, not proof of GitHub upload |
| Full `make test`, new variables unset, `CI=true` | FAIL overall: UI runner initialization timed out enabling automation. F2 79 tests; MarkdownCore 303; EditorKit 392 (7 skips); PreviewKit 61; WorkspaceKit 356; sandbox-root check; App hosted 703 (1 skip); PerformanceTests 25 all passed. Runtime resource preflight logged exactly once. `/private/tmp/h23-make-test.log` |
| Preview suite after interrupted make flow | PASS, 127 tests; `/private/tmp/h23-preview-tests.log` |
| Pinned lint | PASS, 0 serious violations; known warnings retained. SwiftFormat 0.62.1 binary matches the binary in the zip whose SHA-256 is pinned by CI. `/private/tmp/h23-final-lint.log` |
| Workflow | Local Psych YAML parser PASS; reviewed expressions, paths and failure conditions. `actionlint` unavailable. `gh workflow view CI --yaml` fetched current remote workflow for comparison; the published workflow subsequently ran its build, preflight, tests, failure summary and upload steps successfully |
| `git diff --check` | PASS |

The machine did not qualify for idle measurement. `CI=true` uses the existing informational
wall-clock behavior for functional validation; none of these numbers close performance gates.
The full suite is **not green**. A separate unchanged-main baseline run, restricted to
PlainsongUITests, passed all 29 tests after rebuilding with isolated DerivedData:
`/private/tmp/h23-ui-baseline.log` and `/private/tmp/h23-ui-baseline.xcresult`.
That run initialized automation successfully. It differs in scope and DerivedData from the
failed combined run, so it does not identify the cause, prove a persistent environment failure,
or turn the changed-head full suite green. No owner-only input/VoiceOver gate is closed.

## Hosted failure artifact verification

[PR #141](https://github.com/w3d-su/plainsong/pull/141) deliberately ran probe commit
`1afcfda8b0ab38203d8696af90825a88707acd4d` in
[CI run 37176591675/a1](https://github.com/w3d-su/plainsong/actions/runs/37176591675?attempt=1).
The failure/cancellation capture and upload steps both succeeded. Artifact
`plainsong-ci-failure-37176591675-1` (ID `11293738590`) is 101,436,958 bytes;
expiry `2026-10-18T04:35:46Z` confirms 14-day retention.

The complete downloaded ZIP matched the official SHA-256:
`815a3f08c33bf53eabde15b21a03d6473cd88f8516de85c73e7eee53b78ca221`.
CRC validation passed before extraction. The xcresult bundle, build-for-testing/test/preflight
logs, resource manifest and environment summary were present and non-empty. All 67 resource
hashes matched PR source, including editor/open/memory fixtures, preview files and fonts.
`xcresulttool get test-results summary` successfully decoded the bundle: 758 tests, 755 passed,
2 failed, 1 skipped. One failure was the intended `CIFailureArtifactUploadProbeTests` assertion.

The artifact also caught an unintended 500 KB fixture load failure even though both preflight
passes read/hash-verified it. Its displayed URL retained a relative bundle base. The initial
refactor had replaced the original Bundle resource lookup with resourceURL appending; this
is corrected by restoring `Bundle.url(forResource:withExtension:subdirectory:)` and taking
`absoluteURL` before anchored file loading. Diagnostic helper URLs are also explicitly absolute.
This follows [Apple's absoluteURL contract](https://developer.apple.com/documentation/foundation/url/absoluteurl).
It is a compatibility correction to this change, not a claim to have fixed the historical
resource/CAS flake. That historical root cause remains unknown.

Two final-source local named tests passed under the shared lock:
`testBundledFixtureURLsRemainAbsoluteForAnchoredReads` checks absolute spelling/no base and
successful descriptor authority capture for the four representative fixture/preview URLs;
`testOpening500KBMarkdownToEditorFirstPaintStaysUnderBudget` verifies the actual file-load path.
Log: `/private/tmp/h23-resource-url-tests-final.log`; pinned lint also passed after the correction.
These were CI-mode functional checks, not idle budget measurements.

Inspection metadata is retained in `docs/evidence/ci-failure-evidence-37176591675.json`.
Full downloaded artifact: `/private/tmp/h23-probe-artifact-37176591675/`;
parsed summary: `/private/tmp/h23-probe-xcresult-summary.json`.
The deliberate probe is removed in a new revert commit, never by force-push.
Final exact-head normal CI and success upload-skip are checked and reported in the PR body
when that run completes. No local full-suite or owner-only gate is relabelled green.
