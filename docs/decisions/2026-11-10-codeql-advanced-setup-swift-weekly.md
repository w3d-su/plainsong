# CodeQL moves to advanced setup, and Swift analysis runs weekly instead of on every push

CodeQL default setup ran `Analyze (swift)` on a macOS runner for every pull request push
and every commit on `main`. GitHub caps the repository at five concurrent macOS runners,
and a CI run needs three of them (four after
`docs/decisions/2026-11-02-ci-one-hosted-build-and-main-runs.md`). Over the 150 CI runs
from 2026-10-25 to 2026-11-06, a run that started alone took a median of 13.1 minutes and
a run with five or more others started within ten minutes took 60.4. Over the last 22
successful default-setup runs the Swift analysis held a runner for a median of 13.0
minutes per push (7.4 to 15.5).

The owner decided on 2026-11-10 to run Swift analysis on a schedule.

## Decisions

- **Advanced setup replaces default setup.** Default setup cannot set a trigger per
  language, and GitHub rejects CodeQL results from a workflow while default setup is
  enabled. Default setup is therefore turned off in the repository settings, and two
  workflow files take over.
- **`codeql.yml`** analyzes `actions`, `c-cpp`, `javascript-typescript` and `python` on
  Ubuntu with build mode `none`, for every pull request, every `main` commit and weekly.
  These are the languages, build mode and triggers default setup used.
- **`codeql-swift.yml`** analyzes Swift weekly, on `workflow_dispatch`, and on a pull
  request that changes that file.
- **Swift uses a manual build of the app scheme (`make build`).** Default setup's autobuild
  ran `swift build` in one package. In run 42688099878 it compiled MarkdownCore,
  WorkspaceCore, Yams and `IOSAcceptanceHarness`, and nothing from App, EditorKit,
  PreviewKit, WorkspaceKit or SyntaxKit. Swift analysis has never reported an alert.
- **Both workflows keep default setup's `/language:<name>` categories**, so existing
  alerts keep their history.

## What this gives up

A pull request that changes Swift no longer gets a Swift analysis before it merges. A
finding appears after the next weekly run, or after a manual run of `CodeQL (Swift)`.
The iOS-only targets (AppIOS, EditorKitIOS, WorkspaceKitIOS) are not in the macOS app
scheme and are not analyzed.

## Alternatives considered

- Removing Swift from default setup's languages: one settings change and no workflow
  file, but Swift would never be analyzed.
- Keeping default setup and adding a scheduled Swift workflow: GitHub rejects the upload
  while default setup is enabled.
- Keeping autobuild in the weekly job: cheaper, but it analyzes two of the macOS packages
  and none of the code that handles files, the sandbox or the web view.
- A self-hosted or larger runner for Swift: a recurring cost for a weekly job.
