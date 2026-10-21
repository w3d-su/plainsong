# Bind an iOS document admission to its issuance and split phase B start from final acceptance

Ticket equality included only `IOSDocumentIdentity`, so after the same document was admitted again the older ticket's `end` cleared the new ticket and a second document was accepted. Each `begin` now stores a new issuance, and `end` releases only that value. The app still does not call the admission. Phase B wiring waits for M0 IME/Undo, Files/iCloud, background save, a pre-composition owner re-sign, the lane 06 service, and a recorded lane 07 package-host bundle result. Lane 11 product acceptance and the lane 12 IPA of the composed head are final acceptance because they require the wired binary. Alternatives rejected: treating document identity as the ticket, and requiring the composed product suite or composed IPA before wiring can start.

Preserved from the iOS review branch during main integration. Status and head
references above describe the original decision date; current evidence is tracked in
[`docs/ios/integration-ledger.md`](../ios/integration-ledger.md).
