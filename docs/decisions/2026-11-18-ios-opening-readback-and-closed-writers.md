# Serialize iOS opening readbacks and release closed writers

A UIDocument provider can report a file change after `open` or `create` has captured its
first snapshot but before the store publishes the session. The store finishes a coordinated
readback for each reported change before installing that first session, so neither the first
opener nor a coalesced opener can overwrite bytes the provider already reported.

If the readback fails, the last verified bytes remain an untouched read-only snapshot. An
unedited snapshot may close without a recovery copy because closing it cannot discard user
work. Close does not wait for a permission-verification read that is still probing such a
snapshot. A later external read that matches those bytes, or a Reload accepted by the editor,
restores write access from the provider's current permission. Permission notices that arrive
during opening readback replace the initial open result at installation. If that readback
fails, a writable notice received before installation is deferred like a queued change notice
and starts one verification read after the session is published. If the readback succeeds,
the notice supplies only the initial permission and does not reread bytes by itself.

A write whose outcome is indeterminate invalidates the saved baseline. Undoing back to the
previous text is not proof that the provider stored those bytes, so the document stays dirty
and fenced until fresh provider bytes are read. Background recovery checkpoints live text
when a different snapshot is still in flight.

Closing a document releases its session, writer, leases, and file-handler closure. The store
keeps only the terminal access generation for the 128 most recent closed identities so a
scene can query or repeat retirement without retaining document contents. Older or unknown
identities are indistinguishable and retirement for them is a no-op.

Alternatives:
- Block opening until every transient provider read succeeds: one offline or unavailable
  provider can keep the document UI from opening even though a verified snapshot exists.
- Retain every closed writer and session: preserves exact history but leaks text and provider
  objects for documents the user already closed.
- Treat an indeterminate write as saved when Undo returns to the old text: can acknowledge
  bytes the provider never committed.
