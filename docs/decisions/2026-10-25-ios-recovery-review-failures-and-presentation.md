# Make recovery failures and presentation handoffs explicit

Date: 2026-10-25. Review repair for the integrated iOS production composition (#211).

Recovery still closes the previous writer safely before adopting a destination
folder and creating a new file. A provider can refuse that create after its earlier
directory snapshot passed (for example, a competing create). If no new writer was
returned, composition releases the destination and reports a distinct failure:
the prior document safely closed, its folder is no longer open, and the user can
close Recovered Drafts and use Open to reopen the previous file/folder, or retry
recovery into another folder. This operation neither overwrites the original nor
consumes the durable draft. An asynchronously returned writer still remains
installed/admitted on a later refusal; it is never discarded to make rollback look
successful. Early source, grant and retained-close refusals keep their old behavior.

Automatic reopening of the former location was rejected: its old security scope
has been retired, the provider may have changed, and another suspended open would
require new authority and safe-drain handling. The explicit Open route obtains a
fresh grant and leaves failures visible instead of claiming transactional rollback.

The production scene now injects the concrete access service's transient
`openDestinationFolder` path. A restore destination is not an opened recent
workspace, so selecting it does not add, refresh, reorder or evict recent records.
The fallback protocol opener exists only for explicit test/custom composition;
no frozen access or document declaration changes.

Each Restore issuance proposes the original leaf name plus `-Recovered-` and a
fresh short UUID, retaining `.mdx` when appropriate. The metadata path must pass
WorkspaceRelativePath lexical validation; delimiters and control characters are
removed from its leaf stem, which is limited to 180 UTF-8 bytes. Invalid or empty
metadata uses a safe Recovered fallback. The same issuance keeps the same name
across suspension; a later restore obtains another name. The store's
create-new-leaf check remains the authority for late collisions. The original
stored path is display metadata only. Lists group by exact filename and then newer
revision before UUID tie-breaking. Existing records have no capture timestamp, so
no synthetic time is displayed or presented as chronological history.

Recovered Drafts moves from a permanent row below the editor into the Files
toolbar. A successful restore requests sheet dismissal first; only the actual
matching presentation's `onDismiss` consumes its navigation handoff once. Old or
duplicate appearance/dismissal callbacks cannot dismiss a new issuance or navigate
it. External cancellation invalidates a suspended provider's capture and clears
pending navigation while retaining the busy operation until it drains.

Focused regressions cover a late create refusal after close/adoption, explicit
fresh-grant reopen and restore retry, original-source/draft retention, one-time
post-dismiss navigation and stale callbacks, provider-drain cancellation, distinct
original-leaf restore names, and filename/revision list ordering. The production
UIDocument workflow also checks that the destination never appears in recents and
navigation waits for dismissal. Native/CI results remain source-bound and are
recorded separately by the integration owner; this entry is not a device acceptance
or an assertion that any new test has executed.
