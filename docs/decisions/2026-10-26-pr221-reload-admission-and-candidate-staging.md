# Revalidate deferred reloads and staged replacement candidates

Date: 2026-10-26

## Decision

The production reload relay synchronously asks the document store to admit a
proposal immediately before native installation. `IOSDocumentReloadAdmitting`
is an additive implementation capability outside the frozen C0 facade. The
UIDocument store checks its current pending operation, identity, revision and
live grant. Close, retirement and a closed provider hold an otherwise current
proposal; the relay returns deferred without retiring its operation ID. A
successful close discards it, while a failed close can resume it after closing
ends. Ordinary pending and explicitly requested conflict reloads do not depend
on the provider's `canWrite` flag. Frozen declarations and dependency pins do
not change.

Watcher coalescing uses typed root/child keys and includes workspace identity,
generation and root token. Child paths use their exact UTF-8 identity. A child
named `root-moved`, `root-deleted`, `root-changed` or `offline` cannot replace a
root notice, and canonically equivalent path spellings remain distinct.

M0 installs observation callbacks before opening a replacement candidate. A
revert, post-open availability loss, incompatible state or changed URL refuses
that replacement attempt. If the original document already closed, reopen it
while retaining its existing editor identity, source, selection and grant.
Failed candidate disposal retains its grant until a successful retry. The user
can retry the selection to open fresh provider bytes.

## Why

PR #221 review found that an already published deferred proposal could install
while provider close awaited. Its acknowledgement was refused during closing,
leaving dirty source and a pending operation the relay had already retired.
Suppressing only newly published proposals did not withdraw the relay's copy.
The same review found root-notice/path key collisions and a replacement
candidate window where external reverts were dropped before attachment.

## Alternatives

The existing read-only state cannot distinguish ordinary pending reload from
close, so gating on `canWrite` would prevent valid reloads. Retaining every
pending proposal prevents the intended clean no-write close. Accepting a late
installation acknowledgement would still install foreign source during close.
Encoding root markers as ordinary path strings cannot provide disjoint keys.
Silently attaching a candidate's earlier bytes after a dropped revert presents
an obsolete saved baseline; refusing the attempt preserves the working editor.

## Validation boundaries

Native app-hosted and package regressions cover deferred close success/failure,
revocation, explicit conflict reload, batched notice order and candidate staging.
Source-bound simulator evidence and negative probes are recorded separately from
exact publication-head CI. Owner physical-device, Files/iCloud, signing, IME,
background, performance and accessibility gates remain open.
