# Integrate reviewed iOS phase A without regressing the maintained Mac branch

The iOS aggregate and main advanced independently. Main pins STTextView 2.4.1,
passes pre-expanded highlighting coverage to avoid rescanning a large document,
moves preview asset context into its own file, and adds Mac PDF capture. Combining
the branches must retain those changes together with SyntaxKit extraction, iOS
grant-only resource context, and the exact dependency/target inventory.

Keep STTextView 2.4.1 in the package and architecture assertion. Move main's
pre-expanded tokenization entry into shared SyntaxKit while keeping the Mac
compatibility alias; a regression checks UTF-16 offsets and that supplied coverage
does not expand into an unrelated tail. Keep one asset-context type and append the
iOS explicit-grant helper alongside it. Mac PDF capture/measurement stay under a
macOS compile guard; pure geometry and PDF data tests stay portable. No iOS export
UI or production capability is enabled.

Preserve main's Decision Log archive byte for byte and transfer all 11 incoming
iOS decisions to separate dated files, retaining their historical rationale.
Current acceptance is tracked in the iOS ledger instead of rewriting old receipts.
Production composition still supplies five nil capabilities; M0/device/signing and
composed-product gates remain open.

Alternatives: restoring the old STTextView pin or the second viewport scan would
regress main's performance work; copying the extracted parser back into EditorKit
would duplicate grammar ownership; duplicating asset-context types would break the
shared module; exposing Mac capture code to UIKit would expand unvalidated scope;
appending the old iOS rows to the immutable archive would reintroduce shared-line
conflicts. A green historical component result cannot substitute for tests of the
combined source.
