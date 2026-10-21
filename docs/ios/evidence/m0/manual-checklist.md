# M0 owner device checklist — OPEN

Use only `Prototypes/iOSM0/Fixtures/m0.md` and disposable copies, one in Files
“On My iPhone/iPad”, one in iCloud Drive. Record the fixture SHA-256, exact app
source commit, IPA SHA, Xcode/SDK, model, OS, input method, UTC start/end, expected
and actual UTF-16 source/selection, marked range and dirty/saving/conflict state.
Complete both an iPhone and an iPad on iOS/iPadOS 26. A newer OS is additional
evidence, not proof for the minimum. Never include device UDIDs, bookmarks,
profiles, certificates, private URLs or account names. Export the redacted event
log and pair it with screenshots/video of this public fixture only.

On this Mac acquire the shared lock for the whole manual run:

```sh
lockf -t 0 -k /private/tmp/plainsong-xcodebuild-test.lock /bin/zsh
# Perform signing/install/device run while this shell holds the lock.
# Do not invoke Scripts/run.sh inside it. Exit when device work finishes.
```

The result template is `owner-result-template.json`; make a separate result file
for each device/input/provider/attempt. OPEN is the default, never a placeholder
PASS. An actual content loss, composition interruption, selection jump, extra
Undo or unauthorized overwrite is FAIL and stops production composition.

| Gate | Sequence | Required expected result |
|---|---|---|
| M0-IME | Enable Traditional Chinese Zhuyin. Create candidates; modify/delete composition, choose candidate, compose next to heading, between emoji/ZWJ and across lines. Repeat with Traditional Chinese Pinyin. | Real marked range/event trace; committed source exactly matches intended text, no candidate cancellation from delayed styling. |
| M0-IME Undo | Type a Chinese phrase, paste public fixture text, select across lines/emoji, delete, Undo each native action then Redo. Repeat with iPad hardware keyboard if available. | Compare exact source and UTF-16 selection at each step; no presentation action in history. While composing, Undo/Redo controls refuse without touching marked text. |
| M0-Presentation | Delay ON; type, move caret, select text; wait for old work; switch clean documents before old coloring returns; rotate/resize iPad, show/dismiss View switch. | Stale callbacks recorded as refused. Source, selection and full Undo/Redo sequence unchanged without an extra user edit. TextKit2 stays enabled. |
| M0-Files local | File picker opens local fixture in place; edit/save/reopen through Files. Folder picker selects disposable folder and opens its Markdown leaf. | Same external file bytes changed; no import-copy substitution. Single-file grant cannot enumerate parent or read sibling image; Folder grant is explicit. |
| M0-Files iCloud | Repeat file/folder selection in iCloud Drive; remove local download from another device, select the cloud-only fixture; wait for download. | Waiting/failure is visible, no empty text as success. Confirm actual remote bytes after save and sync. |
| M0-Files recent | Quit/relaunch, press Recent; move/delete grant root in Files; retry Recent; revoke provider access or log out of test provider if feasible. | Bookmark restores authorized scope or fails visibly; stale/denied grants require reselection. No silent parent/sibling fallback. |
| M0-Files adverse | Disable network with an undownloaded iCloud fixture; deny access; use a genuinely read-only provider file; move/delete selected file from Files/another device. | Errors remain visible; live/recovery source retained; no silently relocated writable copy presented as original-save success. |
| M0-Save N/N+1 | Delay ON. Edit N, press Save, type N+1 within 3 seconds; observe save acknowledgement. Inspect disk from Files, then press Save again. | First disk=N, editor=N+1 and dirty=true. Second disk=N+1, dirty=false. No older acknowledgement can alter current source. |
| M0-Save conflict | Dirty local source; change same provider file externally before/during delayed save; wait for event. Also press External probe while dirty. | Recovery contains local source, overwrite blocked, external bytes retained. Save copy creates a new file with exact local bytes and does not clear conflict/dirty. |
| M0-Save clean reload | With clean file, edit externally on another device; return to app. Repeat while candidate text exists. | Clean noncomposing reload uses new bytes. Busy/composing reload refuses and preserves current native state with recovery. |
| M0-Save background | Edit, Home/app-switch, wait, foreground; repeat during delayed save and network loss; lock device. | Best effort flush or explicit failure; recovery readback verified. Dirty remains when completion is unconfirmed. |
| M0-Save termination | After an unsaved edit and recovery readback event, terminate app; relaunch and open Recovery before selecting another file. Repeat on background expiry. | Exact prior source/revision is readable from recovery. If killed before readback confirmation, report the gap; never invent durability. |
| M0-Install | Owner re-signs the exact unsigned prototype IPA using their chosen supported tool locally, installs to both devices, launches, selects real Files/iCloud fixture, edits/saves/reopens. | Record tool name/version, method, redacted errors and real launch/read/write/reopen result. IPA generation alone cannot PASS. |

Signing procedure: build `Scripts/run.sh ipa` outside the manual lock shell; copy
the exact IPA to the owner's signing tool. The owner supplies bundle-ID/team
policy, local signing credentials and provisioning; none are shipped with this
spike. Re-sign, verify the signed application/provisioning using that tool's
normal validation, install on an eligible device with Developer Mode where
required, and execute the final row. Record expiry/entitlement-related failures
without storing secrets. There is no selected signing tool/account in this run,
so its tool-specific commands and successful installation remain OPEN.

For every FAIL record minimal steps, expected/actual source UTF-16 and selection,
timestamped relevant probe events, source commit/fixture hash, lifecycle/provider
state, and whether a readback-confirmed recovery exists. Preserve the failed
attempt and any later rerun separately. Do not weaken guards or retry indefinitely.
