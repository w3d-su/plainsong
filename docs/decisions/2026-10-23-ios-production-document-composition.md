# Compose the iOS source editor and Files document providers

Date: 2026-10-23. Contract: IOS-C0-v1, unchanged.

The owner reported PASS for the four explicitly named pre-composition M0
categories on the inherited iPhone 14 Pro/iOS27 context: Chinese IME/native
Undo-Redo, local Files/iCloud file and folder open/save/reopen, background
save/recovery, and re-sign/install. The exact question and reply are retained in
`docs/ios/evidence/m0/owner-retest-20261023/`. This is owner-reported admission,
not full device-matrix or signed-artifact measurement.

Composition uses one existing IOSWorkspaceAccessService for grant/coordination,
preview assets and image transactions, one IOSUIDocumentStore/UIDocument writer,
one IOSSourceEditorController attached to the store's exact DocumentSession,
and one retained PreviewController per supported scene. Link the real PreviewKit
product in the app target; preserve the isolated IOSPreview test host and C0 nil
sentinel regression tests. No frozen declaration, wire protocol or dependency pin
changes. SwiftUI scene-owned StateObject retains the runtime.

Only explicit picker/OS Open URL selections call openPickedURL to mint a new
grant. Browser rows and preview links use matching existing provider descriptors.
Open transitions reserve admission before awaiting I/O; a second open is refused.
Close must safely drain and return closed before another writer may open. A
retained draft keeps its session and ticket. A store handle returned after grant
revocation remains admitted read-only until safe close, rather than being lost.
Revision save acknowledgements stay inside the store and never reload live text.

External reloads pass through a synchronous editor-install/store-ack relay. Epoch,
binding, access, revision and operation guards fence delayed callbacks and replay;
marked text defers the native reconciliation. Operation tombstones last for the
relay lifetime because opaque UUIDs cannot safely be evicted by order. Image and
authoring surfaces use existing guarded native commands. No shadow editable text,
FileDocument writer, URL/inode deduplication authority or success stub is added.

Validation remains split: current-source full PreviewKit readiness, native module/
workflow execution, exact-head Mac CI, unsigned Release IPA structure and later
owner installation of the composed artifact. An interrupted full-preview run and
its independent first-controller pass remain separately retained. Production
publication requires the complete candidate checks; final iPad/OS26, hardware
keyboard, VoiceOver and performance acceptance remain open until measured.

Alternatives rejected: recreating completed lane modules; a second FileDocument
writer; copying selected Files resources into app-private storage to pretend
in-place editing; enabling product acceptance from mocks or historical CI.

Scene-disconnect disposal flushes and safely closes before invalidating its grant.
A retained close keeps the writer and admission. Only an opaque admission value is
shared across production runtime recreations for the single-window scope; no
session, editable text, grant or current-writer singleton is shared. Each scene
ends only its own ticket. This prevents a discarded scene's pending writer from
being duplicated by a later runtime. Transient sheet disappearance only stops UI
observation. Initial facade observation emits the current snapshot, and active
binding changes restore document command focus without crossing background or
replacement bindings. Preview checkboxes use the same native guarded editor path.
