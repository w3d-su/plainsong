# The workspace watcher has a maximum delay and drops batches in skipped subtrees

**Finding.** Every FSEvents batch restarted the 300 ms debounce, with no maximum wait, and
the callback never looked at the paths. A dev server rewriting `node_modules/.vite`, or a
long `git` operation inside `.git`, could keep restarting it, so the Files tree and the
open documents' external-change checks stalled for as long as the writer kept going, even
though the default scan never enumerates those directories. Separately, the search sidebar
rebuilt every result row for each streamed progress update: its presentation memo compares
the whole search state, and the progress counts change on every completed file.

**Decision.**

- `WorkspaceEventWatcher` runs the handler at most `maximumDelayNanoseconds` (2 s) after
  the first batch it has not handled. A token check also stops a superseded debounce task
  from firing in the window between its cancellation check and the queue hop.
- `WorkspaceEventPathFilter` drops a batch only when "Show all files" is off and every path
  lies in a subtree the scan skips: below an ignored directory and off the chain to an open
  document. Paths outside the root, events without a path and every rescan, drop, mount and
  root-change flag always count. The App hands the watcher the scan's own
  `WorkspaceScanPruning` at each reload and each document switch, so a document opened
  inside `dist/` keeps its external-change checks before the next rescan.
- `WorkspaceSearchResultSectionsCache` keeps the result sections of the unchanged leading
  file results and builds only the rest. A progress-only update builds no rows, and an
  appended file builds one section. A new query generation rebuilds all of them.

**Not changed.** A relevant batch still triggers a full rescan. Using the event paths for
an incremental rescan is a larger change to the reconcile and proof pipeline.

**Tests.** `WorkspaceEventWatcherTests`: batches every 20 ms against a 60 ms debounce still
reach the handler by the 200 ms maximum; an ignored-only batch never reaches the handler
and a mixed one does; the filter keeps retained chains, flags, `Show all files` and
paths outside the root. `WorkspaceSearchResultsPresentationTests`: 49 progress updates build
no section, an append builds one, and rewrites and new generations rebuild.

**Alternatives rejected.** A maximum delay alone: during continuous writes in an ignored
directory it would rescan the whole tree every 2 s. Filtering in the App after the debounce:
the ignored batches would still restart it.
