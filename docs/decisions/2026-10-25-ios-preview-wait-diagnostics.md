# Preserve Preview wait failure boundaries

Date: 2026-10-25. Integration-owner diagnostic follow-up to review H5 validation.

Unexpected exported-HTML test failures were retained at their actual sources.
The associated xcresult error domain names a private Gestures state machine, but
its originating await and platform mechanism are unconfirmed. A new same-type
simulator profile also failed; profile-only causality was not established.

Test helpers now log cancellation, condition, sleep, their own timeout and
JavaScript callback/deadline failure boundaries. They rethrow the exact original
error and retain every original timeout, poll clock, callback single-resume gate,
late-reply refusal and assertion. Targeted title/offline phase markers identify
which awaited stage was active; source text and full scripts are not logged.
The unsupported legacy comment attributing InvalidTransition to undefined script
results is removed. No production retry policy is changed by these diagnostics.

A diagnostic subset is explicitly separate from full IOSPreview acceptance. Its
success cannot certify the full required inventory. Neither these source changes
nor private error names establish a product root cause or physical acceptance.
