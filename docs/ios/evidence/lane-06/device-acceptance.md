# Lane 06 device gates

These gates stay **open**. The simulator scripted provider and one local temp-file bookmark round trip do not close them. No signed install or owner recording is claimed.

| Gate | What the owner checks | Status |
|---|---|---|
| Single file from Files | Pick one `.md` from On My iPhone. A sibling in the same folder cannot be read or previewed. Relaunch restores that file from the recent list. Revoking the grant in Files rejects the next read | Open |
| Folder from Files | Pick a content folder. The tree lists documents and images from immediately available metadata. Undownloaded bodies stay placeholders. Turning the device offline keeps the last complete tree and any unsaved editor session | Open |
| iCloud identity | Two opens of the same provider item dedupe in Recents by the provider's opaque identity. Two different items that share a display name stay separate. URL and inode are not the identity | Open |
| Stale bookmark | After the file is moved in Files, restore asks for reselection and does not attach the grant to a different file | Open |
| In-flight revoke | Invalidate or revoke access while a coordinated read is parked. The late bytes are dropped. The scope ends only after that read drains | Open |
| Image publish | With a folder grant, a failed image save removes that operation's leaf only when the same coordinated remove proves the provider identity. Otherwise the leaf stays and the caller keeps a receipt. A single-file grant asks for a folder and writes nothing next to the Markdown file | Open |
| External change | Edit the open file in Files while the editor is clean, then while it is dirty. Lane 06 reports the change on that grant only. The same relative path in another open folder is not the same event. Lane 05 decides reload versus conflict. The session URL stays the granted URL | Open |
| Traditional Chinese IME | An external notice arrives during Zhuyin or Pinyin marked text. This lane does not install the external text. Editor composition belongs to lane 04 | Open |

Record the device, iOS build, and the file provider (On My iPhone or iCloud Drive) next to any future pass. Leave the status Open until that recording is in the same commit.
