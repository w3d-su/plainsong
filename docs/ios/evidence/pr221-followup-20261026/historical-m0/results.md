# M0 current local receipt — owner gates OPEN

The canonical main-facing implementation is `151ac66067745594480123dcf294e0fe533a97b4`.
Its complete M0 hosted run passed **35/35**, with no failures/skips and normal
runner exit 0. Three candidate-staging regressions cover external revert during
old-document close, transient availability loss and failed-disposal grant retention.
Existing background, Fixture/Delay and workflow cases remain selected and passing.

Unsigned IPA SHA-256: `b4fe8eb6630b7aea62e5169fb873f04b858dc7ff8f21e5d76014d0fb5d676bd9`.
The fresh archive is arm64 iPhoneOS, minimum iOS 26, iPhone/iPad, unsigned.
The packaged `m0.md` is 243 bytes, SHA-256 `38b1b6a80749a22baa8cede8adf5af4ee598181ca4690dc4b7d64b6a850c5144`.
Actual ZIP CRC, fixture bytes and artifact hash were verified.

[runs.json](runs.json) binds all 35 named results and prototype input hashes to
[ipa-receipt.json](ipa-receipt.json), including the current artifact path.
The [PR #221 repair packet](../pr221-race-fixes-20261026/README.md) retains complete
logs and negative probes. Its later publication changes evidence only; compiled
module and prototype inputs remain byte-identical to their passing runs.

The earlier 32-case receipt and IPA are preserved unchanged in
[historical results](../pr221-race-fixes-20261026/historical-m0/results.md),
[historical runs](../pr221-race-fixes-20261026/historical-m0/runs.json) and
[historical IPA receipt](../pr221-race-fixes-20261026/historical-m0/ipa-receipt.json).
Earlier pre-round2 records remain in this directory under `historical-before-round2-*`.

Owner signing/install, actual Files/iCloud bookmark restoration, real Chinese
IME/Undo, background suspension/termination, iPad/minimum-OS, accessibility and
measured performance remain OPEN. Local simulator or unsigned IPA evidence does
not close them. This M0 IPA is a prototype artifact, not a production release.
