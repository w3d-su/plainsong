---
title: "M1 Release Checklist"
status: draft
---

# M1 Release Checklist

Use this file as a compact markdown sample for editing, saving, and status-bar checks.

## Build

- [x] Generate Xcode project
- [x] Build app target
- [x] Run package tests
- [x] Run app tests
- [ ] Verify large-file typing latency
- [ ] Replace fallback highlighting with incremental parser highlighting

## Manual Smoke Test

```bash
make format
make lint
make test
make build
```

## Acceptance Notes

The branch can be reviewed once all automated checks are green. Full M1 acceptance still
depends on parser-backed highlighting and a visible-lag check against the large fixture.

## Risks

- Regex highlighting can drift from real markdown parsing.
- Sandboxed bookmark restore needs manual testing on a signed local build.
- Finder open and app relaunch flows are easy to miss in package-only tests.

