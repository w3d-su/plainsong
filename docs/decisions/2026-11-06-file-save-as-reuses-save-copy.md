# File › Save As… reuses Save Copy and moves the session to the new file

Save As (⇧⌘S) writes the shown session's text to the file chosen in a save panel and then
edits that file. Every window showing the session follows it. The original keeps the bytes
it had on disk; unsaved edits reach only the new file. This is the classic macOS Save As,
and it matches Typora (agent.md §17 rule 12).

The write and the rehoming are the Missing File Save Copy path. `saveDetachedCurrentDocument(to:)`
now proves its missing-file prompt and calls `saveShownSessionCopy(from:to:)`, which Save As
calls after the source-side refusals of `save(session:)`: a workspace mutation, pending
editor source, an indeterminate write, or an unresolved external change. Destination
ownership, alias refusal, indeterminate-write quarantine, retirement rehoming, recents, and
Find rekeying are therefore the same as Save Copy; the rekey reaches the Find bar of every
window showing the session. A destination that is the current file, by spelling or by a
canonical path that is a case or normalization alias of it with the retained file identity,
is a plain Save, because the Save Copy owner walk would refuse the session's own file. A
hard link to the current file shares its identity but is another directory entry, so it is
not a plain Save; the owner walk refuses it and neither file is written.

While the panel is open the session cannot autosave from any window. The panel taking key
status resigns the document window, and that focus-loss flush would otherwise write the
unsaved text over the original even if the user cancels. A session still dirty when the
panel closes has its autosave scheduled again.

For a missing file, Save As is the banner's Save Copy. A destination inside the workspace appears in the tree on
the next file-system reload, which selects the shown document. A destination outside it keeps
the workspace open while the window edits the external file, as Save Copy already does.

Alternatives: a separate Save As write path was rejected, because it would duplicate the
ownership and quarantine rules that Save Copy and export already share. Leaving the session
on the original (Save a Copy, as in some editors) was rejected, because the menu title
promises that the window continues with the new name. Running the panel as a window sheet
was deferred; Save Copy and New File both use an app-modal panel today.
