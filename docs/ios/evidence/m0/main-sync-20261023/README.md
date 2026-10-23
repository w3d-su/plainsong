# M0 validation aligned with main — 2026-10-23

PR #188 was squash-merged. This additive merge preserves both #191 history and
main `7d9f1721020d0afe3174bc3a0d988cfa682185ea` without reintroducing archived evidence.
Current main is retained exactly outside the 26 paths changed by #191 since
`e20162e5`; the two M0 index/checklist pages retain main’s archive notes and the
new dated records. No production App/provider, contract or preview source changes
are introduced relative to main.

All 18 prototype inputs equal the clean tested source `806989d`. This source
comparison preserves the meaning of the historical 20/20 iPhone and 20/20 iPad
simulator executions; it does not relabel them as this merge’s executions.
The unexplained clean Fixture readiness timeout, cancelled builds, incomplete
ENOSPC attempts and the deliberately failing writer mutation remain retained.
See [fixture repair](../fixture-fix-20261022/README.md),
[original 17-case runtime](../runtime-20261022/README.md), and
[new owner reports](../owner-retest-20261023/README.md).

The final PR diff includes prototype code/resources and hosted workflow tests,
so standard PR CI must run the full Mac/preview/package/hosted jobs. It does not
execute M0 iOS tests. #202’s green run at `902486d` is historical; current #191
head checks must be read separately. Claude/maintainer review and merge remain
external to this receipt.

[Merge verification](merge-verification.json) records parents and byte equality.
