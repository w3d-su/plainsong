# Lane 02 — SyntaxKit extraction evidence

Date: 2026-10-08. Contract: IOS-C0-v1. This lane does not change frozen contracts, `agent.md`, the Decision Log, `project.yml`, the Makefile, or CI.

## Baseline

| Field | Value |
|---|---|
| IOS_BASE_REF | `refs/tags/ios-c0-v1` |
| IOS_BASE_SHA | `642cb212703220409874a2741c5adbfb8c80fe8a` |
| Branch | `phase3-ios-syntax-kit` |
| Worktree | `/private/tmp/plainsong-ios-syntax-kit` |
| Pre-move snapshot | `pre-move-baseline.json` |
| Snapshot SHA-256 | `308e7319e1a21ea15b6d111820721cf00720ebdcaa6f32c37ffed4b2b835e4b4` |

The snapshot was produced by the Mac parser at the C0 tag, before the files moved, with `SYNTAX_CAPTURE_BASELINE=1`. Later Mac and SyntaxKit runs compare encoded bytes with that file. The hash above is unchanged after the move.

Context7 library id `/tree-sitter/swift-tree-sitter` (High, benchmark 82.5). Current docs say `Parser` assumes UTF-16 and `Node.range` is the UTF-16 translation of `byteRange`. The pinned 0.10.0 source (`f97df585296977d8fcaf644cbde567151d1367b8`) confirms `parse(_:)` calls `ts_parser_parse_string_encoding` with `TSInputEncodingUTF16LE`. `nsRange(for:)` still divides that byte range by two. The first Context7 lookup for the name "SwiftTreeSitter" returned no library; the second lookup used "swift-tree-sitter".

## What moved

- `MarkdownSyntaxParser.swift`, `MarkdownSyntaxParser+MDX.swift`, `WYSIWYGFoldParser.swift`, `WYSIWYGFoldParser+Inline.swift`, and `WYSIWYGFoldModel.swift` now live in SyntaxKit.
- Vendored `TreeSitterTSXFixed` and `TreeSitterYAMLFixed` moved with their license and attribution. Grammar versions were not bumped.
- SyntaxKit's manifest now pins SwiftTreeSitter 0.10.0 (`f97df585`) and tree-sitter-markdown 0.5.3 (`f969cd3a`), the same revisions EditorKit already pinned.
- EditorKit no longer compiles those C targets or declares those package URLs. It depends on SyntaxKit. Mac call sites keep `MarkdownSyntaxParser`, `WYSIWYGFoldParser`, `WYSIWYGFoldPlan`, and `WYSIWYGFoldRegion` through typealiases. `@_exported import SyntaxKit` keeps nested fold kinds visible to existing EditorKit sources.
- `MarkdownSyntaxTokenizer` is the `MarkdownSyntaxTokenizing` provider. It is an actor, returns semantic kind plus absolute UTF-16 ranges, and echoes `requestID`, `version`, and `coveredRange`. It does not return colors, fonts, or attributed strings.

Mac highlight and fold still share one `MarkdownSyntaxParser` inside `MarkdownHighlightService`. The iOS protocol returns source tokens only. Fold presentation stays in EditorKit.

## Module results (Mac)

Command, from `Packages/SyntaxKit`:

```sh
swift test --filter 'SyntaxDifferentialTests|SyntaxProviderTests|SyntaxContractConsumerTests'
```

Result: 8 tests, 0 failures. That is the whole SyntaxKit suite: 1 existing contract consumer, 1 pre-move differential, 6 provider tests (identity, viewport/UTF-16, YAML/fence/TSX/empty/EOF/out-of-range, 250_000-byte full-document cutoff versus visible-range inline parsing, invalid range, cancellation discard, 24 concurrent requests).

Command, from `Packages/EditorKit`:

```sh
swift test --filter 'MarkdownSyntaxHighlighterTests|WYSIWYGFoldModelTests|WYSIWYGLinkFoldingGateTests|EditorHighlightSchedulerTests|EditorReplace(?!WYSIWYGPerformance|BatchSpikeLarge)'
```

Result: 129 tests, 1 failure. The failure is `EditorReplaceLayeringTests.testNoProjectOrPackageDependencyChange`, because that inventory is owned by lane 13 and still lists the grammar packages on EditorKit. The other 128 tests passed, including highlighter, fold model, link folding, highlight scheduler, and Replace suites (`EditorReplaceWYSIWYGTests` 17, `EditorReplaceExecutorTests` 10, batch/publication/write-outcome suites). `testIOSScaffoldDoesNotLinkMacOnlyProviders` passed, so SyntaxKit sources do not import AppKit, UIKit, or WebKit.

The linked EditorKit test binary defines each of `tree_sitter_markdown`, `tree_sitter_markdown_inline`, `tree_sitter_tsx`, and `tree_sitter_yaml` once.

`EditorReplaceWYSIWYGPerformanceTests` and `EditorReplaceBatchSpikeLargeDocumentTests` were not run. They are not this lane's acceptance record.

SwiftFormat 0.62.1 was run on the touched Swift files with `wrapIfStatementBodies` and `wrapIfExpressionBodies` disabled. `git diff --check` is clean. SwiftLint reports no new errors on the touched files. Pre-existing length and complexity warnings moved with the parser.

## iOS compile and real-device gate

iOS compile details are in `ios-compile.md`.

- SyntaxKit `swift build` for `arm64-apple-ios26.0-simulator`: pass.
- `make ios-c0-build`: **TEST BUILD SUCCEEDED** for `PlainsongIOS` on the iOS Simulator SDK, arm64 and x86_64. SyntaxKit object files from that build do not reference AppKit, UIKit, or STTextView.

Real-device gate: **OPEN**. No iPhone or iPad run, no Traditional Chinese IME, no Files/iCloud run, and no on-device typing or highlight budget. The historical 250_000 UTF-8 full-document inline cutoff is still present and is not an iOS visible-range performance pass. M0 has not passed, so this lane does not claim product integration.

## Patch for lane 13

`c0-inventory-patch.md` is the manifest inventory and Decision Log text this lane cannot commit. Until 13 applies it, `testNoProjectOrPackageDependencyChange` fails on this branch.
