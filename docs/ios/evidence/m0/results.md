# M0 current local receipt — owner gates OPEN

The canonical main-facing implementation is `047ac873321c9608fa1c352bac8d1a878985e4e0`.
Its separate complete M0 hosted run passed **32/32**, with no failures/skips and
normal runner exit 0. The five new background regressions cover active completion,
expiry, write refusal, recovery failure and no-writer completion. Main's existing
Fixture/Delay UI and WorkflowTests remain present; historical #156 has its own
29-case receipt and IPA, not this app's receipt.

Canonical unsigned IPA SHA-256:
`e0eb7e2bfabe106ba7fa01ebf0a5cef83fbb1f0c8c69f1416d21d97f99fb9ce7`.
The packaged `m0.md` is 243 bytes, SHA-256
`38b1b6a80749a22baa8cede8adf5af4ee598181ca4690dc4b7d64b6a850c5144`.
The fresh archive is arm64 iPhoneOS, minimum iOS 26, iPhone/iPad, unsigned.
Actual ZIP, fixture, hash and signing-material checks passed independently.
Use this IPA's path in `ipa-receipt.json`; older receipts do not select an install artifact.

[runs.json](runs.json) binds source, full named results, manifests and logs to
[ipa-receipt.json](ipa-receipt.json). The [review packet](../review-round2-20261026/README.md)
retains complete logs and source hashes. The publication after the tested commit
changes evidence only; compiled prototype inputs remain byte-identical.

Owner signing/install, actual Files/iCloud bookmark restoration, real Chinese
IME/Undo, background suspension/termination, iPad/minimum-OS, accessibility and
measured performance remain OPEN. Local simulator or unsigned IPA evidence does
not close them.

Prior timelines and owner reports are preserved unchanged in
[historical results](historical-before-round2-results.md),
[historical runs](historical-before-round2-runs.json) and
[historical IPA receipt](historical-before-round2-ipa-receipt.json).
