# Recent list identity and temporary destination authority

Date: 2026-10-25. Integration-owner review correction for #211, inherited by #217/#218.

Normal document/folder opens remember a single recent record for the same scope
and exact selected/resolved URL path bytes, including when the production provider
has no opaque identity. A matching provider identity also deduplicates within that
scope. Reopening keeps the matched opaque record ID and replaces duplicate rows.
The optional private metadataPath field is backward compatible; legacy bookmarks
can be resolved without UI, mounting or implicit scope access for list matching.

Metadata never grants access. Restore still resolves the opaque bookmark and
requires fresh security scope admission. Paths are not exposed through recent UI
models or logs; Unicode byte spellings remain distinct and scope never widens.

Recovery and Save a Copy destinations use an explicitly selected directory grant
with normal leases and invalidation, but do not insert, refresh, reorder, or evict
recent entries. Selecting a temporary destination is not opening a workspace.
The new API is concrete provider functionality; IOS-C0-v1 declarations are intact.

The integration owner accepts this cross-lane correction after lane receipt: the
visible #218 list exposes the existing Access duplication, and #211/#217 own
transient destination consumers. Adding a second access service, deriving grants
from display names, or changing frozen contracts was rejected. Nine focused
regressions cover nil identity, scope/path/Unicode, legacy and persisted metadata,
and destination grant/drain behavior. Execution evidence is recorded separately.
