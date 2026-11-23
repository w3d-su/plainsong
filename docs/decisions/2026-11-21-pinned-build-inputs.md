# Builds use pinned package revisions, pinned actions and a pinned XcodeGen

Review findings High #47 and #49 (2026-11-21). `Plainsong.xcodeproj` is generated and
not committed, so Xcode resolved the package graph again after every `xcodegen
generate`: Yams floated from 6.2.2, version tags could be moved, and the packages
STTextView and swift-tree-sitter depend on were not named anywhere. Workflows used
movable `@v4` action tags and `brew install xcodegen`. Only Sparkle was pinned to a
revision.

What changed:

- The repository root holds `Package.resolved`, the project's resolved graph with a
  revision for every package. `Scripts/generate-project.sh` (`make generate`, the
  release script and the iOS runners) runs `xcodegen generate` and copies it into the
  generated project.
- `Scripts/release.sh`, `Scripts/ios/run-ios-archive.sh` and
  `Scripts/run-hosted-tests.sh` pass `-onlyUsePackageVersionsFromResolvedFile`. A build
  that would resolve a package the file does not pin fails; the hosted CI build is
  where a stale file shows first.
- Every workflow action is pinned to a commit SHA, every checkout sets
  `persist-credentials: false`, and XcodeGen 2.48.0 is installed by SHA-256
  (`Scripts/ci/install-xcodegen.sh`). `make test-ci-tooling` fails on a tag, a checkout
  that keeps the token, or a Homebrew install in a workflow.

To change a dependency: edit `project.yml` or the package manifest, `make generate`,
`xcodebuild -resolvePackageDependencies -project Plainsong.xcodeproj -scheme Plainsong`,
and copy `Plainsong.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
to the repository root in the same commit. To bump an action or XcodeGen, change the
SHA or the digest together with the version comment.

Not covered: the editor Find F2 performance gate generates its own sealed source
snapshot and records the resolved package input digest instead.

## Alternatives considered

- Commit `Plainsong.xcodeproj` with its `Package.resolved`. Rejected: the project is
  generated (§2), and a committed pbxproj brings back the diffs XcodeGen removes.
- Pin exact versions in `project.yml` only. Rejected: a version tag can be moved, and
  the transitive packages are not named there.
- Keep `@v4` action tags and let Dependabot bump them. Rejected: a tag is movable
  between bumps; a SHA with a version comment is still bumped by the same tooling.
- Keep `brew install xcodegen`. Rejected: Homebrew installs whatever is current, so the
  generated project could change without a commit.
