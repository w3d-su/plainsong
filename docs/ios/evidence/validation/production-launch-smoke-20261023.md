# Production launch smoke contract — 2026-10-23

`make ios-acceptance` runs scheme `IOSAcceptance` and requires one UI case:
`IOSAcceptanceLaunchSmokeTests/testLaunchShowsFilesAndOpenControl`.

The production entrypoint now constructs `IOSProductionRootView`. The previous
scaffold-string assertion no longer describes that entrypoint. The current case
launches the app and waits at most 10 seconds for the Files navigation bar and
the existing `plainsong.ios.browser.open` toolbar control. It also requires that
the Open control is enabled. No new accessibility identifiers are needed.

This case performs no taps, invokes no picker, selects no document, and supplies
no document file-access, editing, live-preview, save/reopen, or device acceptance
result. Those behaviors need their own source-bound integration or owner evidence.
A launch smoke pass also does not establish iPhone/iPad layout coverage.

The required-name manifest and the result-parser synthetic fixture use the new
case name. The public runner keeps its existing admission, resource parity,
required-name, zero-run, skip, and source-provenance checks.

The [phase-B receipt](README.md), [original wiring proposal](wiring-proposal.md),
and [2026-10-15 wiring receipt](../lane-12/acceptance-wiring-20261015.md) preserve
the historical scaffold case and its results. Those results do not execute this
new case. This contract change itself supplies no new simulator or device result.
