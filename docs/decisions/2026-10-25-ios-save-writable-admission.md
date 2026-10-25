# Preserve writable authority in the iOS Save affordance

Date: 2026-10-25. IOS-C0-v1 and the document store write barrier are unchanged.

The chrome previously enabled Save whenever a document was dirty and projected
ready. Both ready and saving states can be explicitly nonwritable while an
external observation is pending or a provider is read only. Include the existing
AND of store authority and editor-binding writability in canSave. A controlled
projection test injects a store barrier after eligibility, keeps a stale writable
editor, then checks independent editor refusal and restored writable admission.

The production workflow previously edited immediately, waited for cold WebKit,
then called Save regardless of current admission. Keep that real first edit and
render. At the warm preview boundary wait for the actual writable binding, make a
second small native edit, and issue exactly one manual Save from its enabled UI
state in the same main-actor turn. Verify the acknowledgement, baseline, actual
bytes, newer preview and reopen. Do not increase the production autosave delay,
retry a refused Save, skip cases or clear an observation barrier.

A prior run refused that programmatic Save with conflict and then retained its
writer during teardown. That is not proof of a real external conflict or a
specific autosave ordering: conflict also represents a transient write barrier.
Its later unavailable cases followed the retained process admission, while the
initial real workflow had already opened its own writer. On a future refusal or
timeout, retain a source-specific writer-state attachment with barrier facts.

Fixture cleanup still records a failed ordinary shutdown. It may then use the
existing provider retirement path to durably preserve, drain and close only that
fixture's writer before retrying shutdown. It never force-ends admission or turns
that cleanup into a product recovery success. Native execution and exact-head CI
remain separate results owned by the integration executor.
