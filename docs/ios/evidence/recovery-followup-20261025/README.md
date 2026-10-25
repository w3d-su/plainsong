# Recovery review follow-up — 2026-10-25

The restored document was installed with the directory snapshot read before its
creation. Restore as New File now refreshes the still-current destination after
creation, before reporting success and dismissing the recovery sheet. It keeps the
existing authority checks, selected destination, original bytes and retained draft.
A deterministic regression changes provider contents during create without sending
any watcher event; the production UIDocument workflow also checks that Files already
contains the new leaf before manual refresh. The new case is required by the native
runner. Execution counts must come from the integration owner's source-bound receipt;
this author did not run the native suite.

The reported cross-module access error is not present in the reviewed source:
`openDestinationFolder` is in a `public extension IOSWorkspaceAccessService`, so its
implicit access is public. The isolated two-module sources here compile the same
shape. `PublicAPI.swift` plus importing `Client.swift` typechecks successfully;
`InternalAPI.swift` is the negative control and rejects that client with an internal
protection error. See `receipt.json` for Apple Swift 6.4 compiler and exact outcomes.
These probes ran under `/private/tmp/plainsong-xcodebuild-test.lock`; they are an
access-control check, not a substitute for the real PlainsongIOS build.

No redundant access modifier or frozen declaration change was made. A directory
refresh failure after creation retains the already installed writer and file; it
cannot roll back the create or revoke the selected destination through this path.
