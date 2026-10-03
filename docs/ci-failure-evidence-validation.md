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
| Workflow | Local Psych YAML parser PASS; reviewed expressions, paths and failure conditions. `actionlint` unavailable. `gh workflow view CI --yaml` fetched current remote workflow for comparison; it does not validate this unpublished revision |
| `git diff --check` | PASS |

The machine did not qualify for idle measurement. `CI=true` uses the existing informational
wall-clock behavior for functional validation; none of these numbers close performance gates.
The full suite is **not green**. A separate unchanged-main baseline run, restricted to
PlainsongUITests, passed all 29 tests after rebuilding with isolated DerivedData:
`/private/tmp/h23-ui-baseline.log` and `/private/tmp/h23-ui-baseline.xcresult`.
That run initialized automation successfully. It differs in scope and DerivedData from the
failed combined run, so it does not identify the cause, prove a persistent environment failure,
or turn the changed-head full suite green. No owner-only input/VoiceOver gate is closed.

## Hosted verification still required

Automatic approval review rejected the external branch pushes as lacking sufficiently explicit
remote authorization. No branch was pushed and no PR/comment or intentional hosted failure was
created. After approval, push the isolated evidence branch, open the requested PR, run one
throwaway env-gated failing-test commit, confirm the failure artifact can be downloaded and
contains the expected files, then add a revert commit (no force-push). Final exact-head CI must
be green and the upload step skipped on success. Do not count the local mocks as this proof.
