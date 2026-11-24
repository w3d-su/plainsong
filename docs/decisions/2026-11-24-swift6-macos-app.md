# Build the macOS app in Swift 6

Select Swift 6 language mode for the `Plainsong` macOS target in `project.yml`
(migration step 11). Leave the other targets' language modes unchanged.

Keep window state and routing on the main actor. Objective-C delegate lookup and
forwarding hooks are nonisolated: a lock protects the wrapped delegate reference,
not the AppKit delegate methods. Nonisolated observation owners remove their
notification tokens on release without calling back into main-actor state.

Declare framework callback closures explicitly `@Sendable` when the caller does
not guarantee main-actor delivery. Read provider results in the callback and pass
only the decoded value into a main-actor task for the workspace move. Combine
transforms that run before delivery is scheduled to the main run loop must also
be nonisolated.

Alternatives:
- Keep Swift 5 with strict concurrency: leaves actor-boundary issues unenforced.
- Use isolated deinitialization: requires Swift 6.2, newer than Xcode 16.4 in CI.
