# New Window and the Open rule share one queue of scene requests

- Date: 2026-11-06
- Scope: Windows PR D2; WD3 and WD7 in `docs/window-state-gates.md` §5.2, §5.3, and §9.1.

File › New Window is ⇧⌘N and ⌘N stays New File (WD3). The command asks SwiftUI for a new
workspace scene through `WorkspaceWindowRequests`. The next scene on the same registry takes
the oldest waiting request in `WindowFacadeHolder.init`, and the request's action runs when
that scene's window attaches. A request that no scene takes within three seconds, or whose
scene never attaches, is dropped, so a lost open cannot run later in an unrelated window. A
request names its registry: a scene of another registry cannot take it. Every scene is
admitted, so this PR removes C's refused-sibling fallback (`WindowOpenAdmission` still
refuses a façade built to refuse). A sibling's untouched blank takes no ownership record, so
a sibling that goes away before its window closes leaves nothing for a reused address.

`routeOpen` is the §5.2 "Same rule as Open". File › Open…, Open Recent, the empty state, a
preview link to a file outside the root, and New File's save panel start in the window that
received the command. Finder, the Dock, and `open -a` start in the frontmost workspace window
by AppKit z-order (`openExternalFile`). WD1 runs first, across every window, this one
included. Then an empty window (no document and no root) takes the open, and any other window
asks for a new window (WD7). So Open… in a window that shows a document opens a new window,
as Typora and TextEdit do. An overlapping root is refused before a window appears, with the
Show action (§4.3). A file inside a root that some window has open opens in the chosen window
as that root's document: the window attaches to the shared root context (WD2) and shows the
file anchored there (W6 bullet 8b). If the open fails in the new window, that window closes
without asking `windowShouldClose` and the error appears in the window the request came
from, so no blank window is left behind.

Only the home window restores at launch: a window that New Window or a WD7 open creates
never restores (§6.1). New File's save panel focuses a window that already shows the chosen
file and writes nothing, because the empty write would replace that document on disk.

Hosted fixtures build their own registries, which no scene ever shows, so their opens stay
in the window they target, as every window did before this PR. Routing tests simulate scenes
by building `WindowFacadeHolder`s and attaching their windows.

Alternatives: `WindowGroup(for:)` with a token per request (rejected for D2: SwiftUI would
persist the presented values for restoration, which is E's decision under WD5); routing an
external event to a new scene by making busy windows stop accepting it in
`handlesExternalEvents` (rejected: SwiftUI's choice between scenes is unverified on macOS 14,
and the new scene would still have to apply WD1 and close itself when the file is already
shown); keeping Open… in the key window (rejected: §5.2 applies the Open rule to menu Open).
