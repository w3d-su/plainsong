# Preserve iOS edits across backgrounding, navigation and iCloud conflicts

The background transition acquires a UIKit assertion before scheduling the existing recovery-first flush. Expiration and completion both release that transition's assertion. Provider acknowledgements determine whether the original was saved.

A scene leaving a fenced document uses the store's existing writer retirement. It persists the latest source, drains provider operations, closes the file and then releases admission. A disconnected scene retries failure with capped backoff. Repeated checkpoint and retention writes reuse their respective record for the same revision. A confirmed matching save may remove its background checkpoint. Conflict drafts and historical records remain available through Recovered Drafts.

An unresolved iCloud version fences writes even when the current file matches the saved baseline. The sheet displays the current and competing versions for explicit selection. Resolution first persists the editor text, then validates the reviewed version identifiers and exact UTF-8 under coordinated write access. The store verifies the chosen bytes on disk before marking the reviewed conflicts resolved. The scene reopens the document with a fresh binding. A new version, changed bytes, revocation or provider failure requires fresh review. A user can also leave the conflict pending or save a copy.

The shared line index and highlight runner live in MarkdownCore. UIKit and AppKit retain their respective focus, layout and highlight presentation. The M0 project remains the separately runnable real-device probe.
