# Transient reads are retried, and a clean detached document reattaches silently

**Finding.** `handleExternalDiskInspection` detached the document on every read outcome
other than `.loaded`, including `.namespaceChanged`, `.unstable` and `.unreadable`, which a
read sees while another tool replaces the file (an atomic save, `git`, a sync client).
Detaching forces `isDirty` and drops the saved-text baseline, and a detached session always
raised Reload / Keep mine when its file read back, even if it was clean and unedited. A
`git checkout` of an open, clean post therefore ended in a conflict banner, and Keep mine
wrote the stale editor text over the checked-out file. The missing-file banner's Close then
discarded the editor copy with one click, although every detached document showed as edited,
so the user could not tell whether it held real edits.

**Decision.**

- `.namespaceChanged`, `.unstable` and `.unreadable` from a watcher inspection are read
  again after 0.2 s, 0.5 s and 1 s before the session detaches. The retry is a registered
  inspection task, so autosave stays fenced while it waits, and any newer disk event
  supersedes it. `.missing` still detaches at once, so a deletion is reported promptly.
  The coherent reader itself still never retries `namespaceChanged`: each retry is a new
  fail-closed read of the same retained location (`docs/workspace-filesystem-contract.md`,
  Coherent reads).
- `markSessionDetachedFromMissingFile` records the state URL and revision of a session that
  was clean when it detached (`cleanDetachedSessionRecords`). It still marks the session
  dirty: if the file stays gone, the editor copy is the only copy and quitting must not drop
  it silently. While the session still has that revision at that URL, a returning file
  reloads it like any clean document (`applyExternalDiskInspection`) and reattaches it on
  activation (`reconcileObservedRetainedFileVersion`). Any edit after detaching keeps the
  old conflict path. `git checkout` unlinks a file before it writes the new one, so this is
  the path that removes the Keep mine trap.
- The banner's Close opens a confirmation dialog (Close Without Saving, Save Copy…,
  Cancel). Its message says whether the editor holds edits beyond the vanished file's text.
  `closeMissingFile()` itself is unchanged, so its callers and tests keep their behavior.

**Not changed.** The Reload / Keep mine resolution read keeps detaching on any non-loaded
outcome; it runs when the user acts, normally after the other tool has finished.

**Tests.** `ExternalChangeTransientReadTests`: each transient outcome is read again and
the new text loads without a detach; outcomes that never settle detach after four reads; a
newer disk event replaces a pending retry; a clean document whose file was removed and
written again reloads silently through both the watcher and activation paths; a document
edited after the removal, or dirty before it, still gets the conflict.

**Alternatives rejected.** Retrying `.missing` as well: it would delay every deletion
banner by 1.7 s and change many existing detach tests, and the clean-reattach rule already
covers a file that comes back. Not marking a clean detached session dirty: termination
would then let its only copy go without asking.
