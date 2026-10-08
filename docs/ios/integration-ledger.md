# iOS Integration Ledger

Created 2026-10-08. Contract specification: IOS-C0-v1. Source snapshot: `b13aa620c7444f2ccd3a8fe3a5b8b0afe0e997b2` (live fetched `main` when the packet was authored).

This ledger is owned by 13. The handoff packet is written; **no C0 scaffold, iOS implementation, real-device gate or IPA is claimed by this document**.

## Shared implementation baseline

| Field | Current value |
|---|---|
| Handoff branch | `phase3-ios-parallel-handoffs` |
| C0 PR / exact head | Not started |
| IOS_BASE_REF | Not published |
| IOS_BASE_SHA | Not published |
| Compiled contract declarations | Pending C0 |
| Global build ownership handed to 12 | Pending C0 |
| Production composition | Pending M0 + providers |

13 replaces placeholders only with verified, fetchable references and exact-head evidence. After C0, this is the single source of shared-base and ownership-transfer facts; other agents do not independently edit it.

## Lane receipts

| Lane | Required reasoning | Branch / PR / head | Provider or double | Executed verification | Open gates |
|---|---|---|---|---|---|
| 01 M0 | L4 | Not started | Separate prototype | None | Device IME/Undo; Files/iCloud; background save; owner re-sign/install |
| 02 SyntaxKit | L4 | Not started | Pending | None | Token/fold differential; Mac regression; iOS compile |
| 03 WorkspaceCore | L3 | Not started | Pending | None | Mac authority sidecar; path/identity tests |
| 04 EditorKitIOS | L4 | Not started | Pending | None | Native Undo; IME; stale guards; real tokenizer |
| 05 Document I/O | L4 | Not started | Pending | None | Serialized saves; persisted baseline; recovery; real provider |
| 06 Access / Browser | L3 + L4 review | Not started | Pending | None | Scoped leases; bookmarks; File Provider; resource/image writer |
| 07 PreviewKit | L4 | Not started | Pending | None | Late resource fences; Mac export regression; iOS rendering |
| 08 Authoring | L3 | Not started | Pending | None | Guarded source edits; Frontmatter; Find/single Replace |
| 09 Images | L4 | Not started | Pending | None | Saved asset before source edit; final grant; ownership rollback |
| 10 Shell | L3 | Not started | Pending | None | View identity; focus; layout; real capability facade |
| 11 Validation | L3 + L4 attribution | Not started | Pending | None | Integration head; device/performance/accessibility matrix |
| 12 Build / IPA | L2 + L3 review | Not started | Pending | None | Simulator/device builds; unsigned structure; owner install |
| 13 Integration | L4 | Not started | Pending | None | C0 freeze; owner evidence; complete production providers |

## M0 owner-only evidence

- [ ] iPhone/iPad models, OS, app/source head and fixture hashes recorded.
- [ ] Actual Traditional Chinese Zhuyin/Pinyin composition, candidate confirmation, selection and native Undo/Redo.
- [ ] Local Files and iCloud Drive file/folder in-place open/save, placeholders/offline, external changes and permission reselect.
- [ ] Background save/recovery and relaunch; older completion cannot erase newer source.
- [ ] Owner-re-signed unsigned IPA launches and opens/saves selected Files resources.

Simulator, test doubles or archive success do not check these boxes.

## Contract changes and ownership transfer

Record date, old/new contract version, exact base/head, affected producers/consumers, compatibility/negative tests, and explicit transfer commit. An unreviewed consumer patch does not change ownership.

## Release receipt

Record separately: local tests; exact-head hosted attempts; Mac regression; owner manual evidence; performance admission; IPA/source hashes and signing-state metadata; installation result. Retain failed attempts and unresolved gates. Claude review is pending until evidence exists.
