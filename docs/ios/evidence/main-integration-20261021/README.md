# iOS phase A main integration — 2026-10-21

This candidate joins main `15913f882b4994280f239fc90ee5f8d52d5f043b` with the
review aggregate `fdd2a071c04f61f5259d31cf17699534d77fce9e` and diagnostic
follow-up `a13c845e3536a147a6dfdbf6ce09c60bf1efda2c`.

## Scope

- Retain main's STTextView 2.4.1 and all Mac editor, preview, sandbox and CI fixes.
- Preserve shared SyntaxKit extraction and main's prepared-coverage parser path.
- Keep one preview asset context with the explicit iOS grant helper.
- Keep AppKit PDF capture and measurement macOS-only; pure geometry remains portable.
- Preserve the Decision Log archive and move all 11 incoming iOS decisions into files.
- Keep frozen IOS-C0-v1 contracts, unavailable C0 composition and disabled acceptance seam.

## Validation status

Combined-source verification is pending. Historical component receipts and green
review-branch CI are not tests of this candidate. Results will be recorded here
with exact source/input boundaries and failures preserved.

The iOS preview gate retains every original required case and its 8 s / 2 s
limits. Pure geometry cases added on main may increase the executed count;
the original required-name set and no-skip gate stay intact.

## Open product gates

M0 physical iPhone/iPad, iOS 26 runtime, Traditional Chinese IME/Undo,
Files/iCloud/offline/conflict/background persistence, owner re-sign/install,
production composition, composed-app acceptance, accessibility/performance and
release IPA remain open. No product provider is installed by this integration.

Maintainer/Claude review and merge remain separate. The agent does not self-merge.
