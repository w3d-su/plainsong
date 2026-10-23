# Browse persisted iOS recovery drafts and restore a new document

Date: 2026-10-23. Contract: IOS-C0-v1, unchanged.

The formal app already writes durable recovery records for conflicts and interrupted
saves, but had no relaunch UI to list, read or restore them. Add a visible Recovered
Drafts entry, a disk-backed list with corrupt-record reporting, immutable read-only
source detail, and Restore as New File through an explicit folder picker. This change
does not add deletion, original-file overwrite, Save a Copy, recents or retry UI.

Presenting the read-only modal cancels any yielded pending editor-focus claim,
releases the scene command route and retires owned authoring captures. It retains
the native editor, source, marked text and Undo. The read-only recovery sheet does
not keep an authoring route into the background editor.

The same concrete IOSUIDocumentStore supplies list and load closures. Its narrow
loadRecovery helper checks the requested record identity. The frozen document and
scene protocols do not change. An optional production-factory recovery directory
allows the actual provider workflow to use an isolated test container directory.

A restore proposal captures record/operation/document identities, revision, literal
source, the installed session object/binding/revision/access context, the current
grant and a scene transition epoch. Picker issuance and read-selection tokens prevent
late completions from retargeting a different selection. Restoring disables native
editing synchronously before its first await and revalidates after record loading,
folder adoption, refresh and safe close. A newer source, replacement binding, revoked
grant, stale request or retained close refuses the proposal without replacing the
live writer. Opaque record paths and old grant metadata are never authorization.

After the old writer safely closes, a narrow adoption helper requires an active
transition, no handle/binding/ticket/process admission, matching snapshot authority
and a live lease admission. With no suspension after the final source checks,
composition adopts the explicitly selected directory and calls the existing
documents.create(initialText:) installation path. The deterministic recovered UUID
filename preserves MDX kind, avoids deriving authority from old filenames and uses
the existing create-not-overwrite semantics. A collision is refused. A writer
returned after late revocation remains admitted read-only under the existing
installer; generic error cleanup must not abandon it.

Recovery source never enters an existing DocumentSession or the external reload
acknowledgement path. The old document is not overwritten or marked saved by the
restore. Successful creation establishes the new document's own persisted baseline.
The original recovery record remains after success and every failure. No automatic
discard is added; a future removal UI needs explicit durable-byte confirmation and
the existing newer-source guard.

Alternatives rejected: creating another document/recovery writer, treating a stored
file path as current permission, installing recovery text into whichever editor is
current after a picker await, clearing admission on retained close, and deleting the
record after a UI success message. A distinct Save a Copy destination flow belongs
to the next independently reviewable feature PR.

Validation is source-specific. Controlled tests cover stale source/binding/epoch,
literal Unicode changes, parked record-read and close races, destination collision
and revocation, retained conflict, picker cancellation/late completion, disk-store
recreation and corrupt sibling retention. The real production-factory workflow
checks new UIDocument creation, one attached session/admission, original bytes and
retained recovery readback. Native execution, exact-head CI, owner installation,
iPad/OS26, VoiceOver, external keyboard and performance remain separate gates.
