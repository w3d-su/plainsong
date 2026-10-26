# M0 current local receipt — owner gates OPEN

The current tested implementation is `ec8eb5c50c7a8ec3524ee9372ea677dbfd29bfe1`. Its official M0 hosted
run passed **38/38**, zero failures/skips, normal exit 0. All 38 names were
separately checked against actual xcresult outcomes. New rollback regressions
cover changed original bytes, canonically equivalent UTF-8 differences and failed
recovery, preserving identity, source, selection, native Undo and grant ownership.

Fresh unsigned prototype IPA SHA-256: `575c957457f4f7a148a87b9fd21fd69fe421df6e68f414f5d91aedeec32b9e55`.
The archive is arm64 iPhoneOS, minimum iOS 26.0, iPhone/iPad,
unsigned. ZIP CRC, exact 243-byte fixture and absence of signing material pass.
Test and IPA manifests bind the same **24 prototype inputs**.

[runs.json](runs.json) and [ipa-receipt.json](ipa-receipt.json) record the artifact
and raw result paths. [Followup packet](../pr221-followup-20261026/README.md)
retains complete logs, source manifests, failed negative probes and restoration
checks. Earlier 35-case/IPA receipts remain unchanged under its `historical-m0/`.

Physical-device Files/iCloud, real Chinese IME, background suspension/termination,
performance, accessibility and owner signing/install gates remain OPEN. This is
an M0 prototype artifact, not a production release.
