# Lane 09 transaction

Contract: IOS-C0-v1. Writer and editor are injected. This lane does not persist with `FileManager` and does not append `DocumentSession.text`.

## Timeline

1. `captureContext` records one editor snapshot, the document location, and the directory grant. A single-file grant, a generation mismatch, a missing focus, read-only, or marked text returns nil. The picker is not a reason to retarget a later caret.
2. Photos uses `PHPickerConfiguration.preferredAssetRepresentationMode = .current` and `selectionLimit = 1`, then `NSItemProvider.loadDataRepresentation`. Files uses `UIDocumentPickerViewController(forOpeningContentTypes:asCopy: true)` and reads that temporary copy. Neither URL becomes the Markdown path.
3. Normalization runs off the main actor. PNG, JPEG, GIF, and WebP pass only when the sniffed bytes, declared type, and filename extension agree and the byte count is at most `MarkdownImageAssetPolicy.maximumFileSizeBytes` (10 MiB). HEIC/HEIF is decoded with ImageIO and written as a new PNG; the PNG bytes are checked again. SVG, executables, and mismatched names are refused before `stage`.
4. `IOSWorkspaceAssetWriting.stage` must return `IOSStagedImageAsset` only after coordinated persistence. `validate` then rechecks that staged leaf. Only after that await returns does the main actor compare the captured binding, document id, revision, selection generation, access generation, `canWrite`, focus, and marked text.
5. The proposal is `SmartPaste.imageInsertion(relativePath:)` over the captured UTF-16 selection. The caret is the end of that insertion. `IOSSourceEditorControlling.apply` is synchronous. There is no await between the fresh snapshot check and `apply`.
6. `.applied` commits the staged asset once. Commit transfers ownership; it does not publish the file. `.committed` and `.retained` are both `inserted`, because the source now references the leaf. Undo/redo is the native text edit only. Undo does not roll the file back.
7. Refusal, cancel, validate failure, illegal relative path, or a changed document/selection/access/namespace calls `rollback` once. `removed` keeps the editor refusal or workspace failure. `retained` becomes `IOSImageInsertionOutcome.retained` and the UI shows the root-relative path. This lane has no delete API.

A second callback, a second `insert`, or a repeated `cancel` joins the terminal task that already started. Picker dismissal and view teardown before persistence call `discardUnstaged` and do not invent a leaf.

## Counterexamples

| Situation | Required result |
|---|---|
| Document switch, or the same version on another document id, during `stage` | No `apply`. One rollback. |
| Native edit, selection generation ABA, access generation, composing, read-only, focus, or binding change | No `apply`. One rollback. The selection range returning to its old value is not enough. |
| Access generation changes after `validate` returns and before `apply` | No `apply`. One rollback. |
| Staged workspace id or grant generation differs from the capture | No `apply`. Rollback. A matching URL prefix is not authority. |
| `validate` throws `grantChanged`, or `stage` throws downloading/offline/read-only/permission/coordination failure | Source text unchanged. Stage failures do not roll back a leaf that was not returned. |
| `stage` returns `retained`, or rollback returns `retained`, or the operation id does not match | No deletion. Recovery keeps the relative path, not the file URL. |
| `apply` returns `.busy` or `.invalidRange` | Source unchanged. One rollback. |
| Cancel flag is set inside `apply` after the source write is accepted | Commit once. Do not roll back a leaf the source already references. |
| Undo, then redo | Markdown disappears and returns. `rollback` stays at zero. |
| HEIC bytes renamed to `.png` without a PNG payload | Rejected before `stage`. A real conversion replaces the bytes and uses a `.png` name. |
| Writer relative path is empty, absolute, `..`, or a `file://` URL | No insertion. One rollback. Deduped `assets/photo-2.png` is inserted verbatim, not the picked URL or the root-relative location. |

## Gates that stay open

Module tests use a private `PausableImageWriter` and `ImageEditorFake` with the frozen protocols. They do not prove lane 06 file-coordinator ownership, lane 04 native Undo, or device Files/iCloud/Photos. Those remain M0/provider gates. Preview display waits on lane 07 using the same authorized root.
