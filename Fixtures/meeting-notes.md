---
title: "Editor Sync Meeting"
date: "2026-06-12"
tags:
  - editor
  - planning
  - fixtures
---

# Editor Sync Meeting

## Agenda

- Review M1 editor scope
- Confirm autosave behavior
- Decide how to measure large-file typing latency
- Capture follow-up work for syntax highlighting

## Notes

The editor should feel predictable for long writing sessions. File opening, save status,
and restore behavior need to be obvious without adding extra chrome to the UI.

> A quiet editor is better than a clever editor when the user is trying to write.

## Decisions

| Topic | Decision | Owner |
| --- | --- | --- |
| Autosave delay | 1 second after edits | App |
| File restore | Restore last opened file on launch | WorkspaceKit |
| Highlighting | Replace regex fallback with Neon/tree-sitter | EditorKit |

## Follow Ups

1. Add measured latency checks for `large-1mb.md`.
2. Add frontmatter and fenced-code highlight snapshots.
3. Verify Finder-opened files route through the app state.

