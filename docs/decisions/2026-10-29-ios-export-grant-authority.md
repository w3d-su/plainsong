# iOS export renders and embeds images under the scene's grant authority

iOS HTML, PDF and Print exported every local image as a placeholder. The export
controller took the Mac path: `setWorkspaceAssetRoot` and `renderForExport(_:)` install
a root context with a random root token and the fixed Mac grant identity. The iOS
access service serves only its own grant record, so every `asset://` load in the export
DOM (what PDF and Print capture) failed as `accessChanged`. HTML embedding read the disk
directly, outside the grant's lease, and the single-file path promoted the document's
parent folder to an asset root.

PreviewKit adds `renderForExport(_:assetAccess:)`. It installs the same provider
authority as the live preview (`updateAuthority`, `grantedAssetContext`). After such a
render, HTML export reads each local image through the installed `PreviewAssetReading`
reader under that authority. The result must answer the same request and authority,
stay inside the root after symlinks, and pass the existing type allowlist, 10 MiB cap and
32 MiB raster budget. A refused read is an omission; nothing falls back to a direct read.
A single-file grant passes no authority, so its local images are placeholders, as in the
live preview. The Mac path (`renderForExport(_:)`) is unchanged.

The iOS exporter also uses the Mac export controller (`makeHTMLExportController`: HTTP(S)
content rule, non-persistent data store). Print renders light and plans pages for the
locale's default paper (US Letter or A4) with a fixed half-inch margin
(`docs/decisions/2026-10-29-ios-review-follow-up.md`). HTML and PDF freeze `system` to the appearance at invocation. The export is
cancelled on scene shutdown, observer teardown and document change, and checks the
document after every await.

Folder search keeps disk reads for re-searches that the open buffer's edits trigger
(bounded to 32 MiB of text). A tree change, an explicit search, or a same-tree refresh reads every file again.
A changed path drops only that cached read
(`docs/decisions/2026-10-29-ios-review-follow-up.md`).
Matching runs off the main actor.

Alternatives: keep the Mac root context and teach the iOS reader to accept it (rejected:
it would authorize reads with no grant record or lease). Copy images into a temporary
folder before export (rejected: a second read path and stale copies). Keep direct disk
reads for HTML only (rejected: they run outside the lease and miss revocation).
