# M0 owner feedback — 2026-10-23

## Earlier targeted retest

The owner reported “測完了都正常” after receiving the repaired M0 kit and being
asked to retest Fixture and the three-second A → Save → B workflow. Those two
workflows were recorded as **OWNER_REPORTED_PASS**. The
[original JSON](owner-retest-20261023-iphone14pro.json) and
[Chinese note](owner-retest-20261023-iphone14pro.md) were copied byte-for-byte
from the retained `ios-m0-fixture-fix-20261022` task artifact and remain unchanged.

That JSON was recorded at `2026-10-23T05:35:02.191243+00:00`. Its
`live_pr_snapshot`, including the old #191 head, #202 merge and CI status, is an
immutable snapshot from that recording time. The note's “已即時核對” has the same
dated scope. Its `production_composition_allowed: false` records the state before
the later explicit four-category follow-up below. These fields are historical
receipts, not a fresh status check for this import or any later PR head.

## Later named pre-composition follow-up

The root conversation then explicitly asked about four missing device categories:
IME candidate confirmation with native Undo/Redo; local Files and iCloud
file/folder open, save and reopen; background save/recovery; and owner re-signing
and installing the fixed IPA. The owner answered **“都測過了，正常”**.

The [additional JSON](owner-followup-20261023-iphone14pro.json) and
[Chinese follow-up note](owner-followup-20261023-iphone14pro.md) preserve the exact
question and response. All four categories are **OWNER_REPORTED_PASS**. This
satisfies the named owner-reported pre-composition conditions for the inherited
**iPhone 14 Pro / iOS 27** context; that context was not independently reconfirmed.
The fixed unsigned IPA and kit hashes remain bound to their earlier delivery;
the installed signed artifact digest and signing tool/version were not supplied.

## Evidence boundary

The reply supplies category-level owner results, without invented detailed steps
or test start/end times. All five complete per-device gates remain **OPEN**:
M0-IME, M0-Presentation, M0-Files, M0-Save and M0-Install. Physical iPad,
iOS/iPadOS 26, the full input/provider/lifecycle checklist, signed-artifact
identity, composed production App acceptance, VoiceOver/keyboard and performance
still require their own evidence. Candidate providers and real-preview readiness
are separate integration conditions. The unexplained historical Fixture
readiness timeout remains retained; this feedback does not establish its cause.

`SHA256SUMS` binds this packet. The original IPA, owner-kit ZIP and
[repair evidence](../fixture-fix-20261022/README.md) remain unchanged.
Current-head CI must be verified and reported separately. This packet does not
rerun native tests or relabel earlier simulator executions.
