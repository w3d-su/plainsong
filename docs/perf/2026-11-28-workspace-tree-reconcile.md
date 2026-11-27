# Reconciling a workspace with 2,000 Markdown files

Measured on 2026-11-28 with an Apple M1 Pro, 16 GB RAM, macOS 27.0 (26A428), Xcode 27.0 (27A5194q) and SwiftPM Debug. The baseline used the WorkspaceCore and WorkspaceKit sources at `d9851d6c36be`. The comparison used the same checkout with the tree builder and comparison-options changes.

## Local 50 ms gate

`WorkspaceFileTreeTests.testReconcileTwoThousandFilesStaysUnderBudget` creates 2,000 Markdown entries in ascending order, followed by their `content` directory. Each entry has a stable identity. The test times the public Mac `reconcile` call with the default filter and no previous tree. Fixture construction happens before the timer starts.

| Input order | Fresh processes per version | Median before → after | P95 before → after | Maximum before → after |
| --- | ---: | ---: | ---: | ---: |
| Original XCTest order | 30 | 25.65 → 16.36 ms | 34.50 → 18.17 ms | 38.97 → 19.40 ms |
| Deterministic permutation | 12 | 124.23 → 87.18 ms | 160.09 → 95.68 ms | 160.09 → 95.68 ms |

The original XCTest passed 12 of 12 isolated baseline runs and 30 of 30 after the first change. An earlier timing probe exceeded 50 ms on 5 of 15 baseline calls in one process. The reported consistent 61 ms failure did not reproduce on this Mac. The first change left the permuted input above 50 ms.

## Profile and procedure

A four-second `sample` trace of repeated baseline reconciles at a 1 ms interval captured 2,299 stacks inside `WorkspaceFileTree.reconcile`. Of those, 948 were in `visibleEntries`, 332 in grouping by parent, 256 in deriving the leaf name during node construction, and 388 in the comparison that calls `WorkspacePathOrder.isBefore`. The builder split visible file paths at each of the first three stages. It now splits each candidate once, retains the name and byte-exact parent key, and stops walking ancestors when it reaches a previously indexed directory. The comparator reuses its Foundation options. On the permuted input, the intermediate build with only the tree builder change had a median of 117.78 ms.

Run the gate from the repository root with `swift test --package-path Packages/WorkspaceKit --filter WorkspaceFileTreeTests.testReconcileTwoThousandFilesStaysUnderBudget`. To repeat the gate in fresh processes after building, use the following command on macOS.

```sh
for run in {1..30}; do
    xcrun xctest -XCTest WorkspaceKitTests.WorkspaceFileTreeTests/testReconcileTwoThousandFilesStaysUnderBudget \
        Packages/WorkspaceKit/.build/debug/WorkspaceKitTests.xctest || break
done
```

For the table, a standalone `swiftc -Onone` probe linked each version of the Debug `libWorkspaceKit.a`. It used the fixture and `DispatchTime` boundaries from the XCTest and printed `elapsedMilliseconds` after the call. Each observation started a fresh process, and launch order rotated across versions. For the permutation, the index for each slot was `(slot * 877) % 2000`. P95 uses the nearest rank. XCTest's displayed case duration also includes fixture setup.

## Follow-up on shuffled siblings

A second `sample` trace used the permuted input on the first revision above. Of 2,238 stacks inside `reconcile`, 1,951 were inside the sibling sort (87%). A direct substitution of `NSString.compare` changed results for Arabic-Indic digits and long sequences of digits on this Mac.

The follow-up prepares one sort key per candidate. For ASCII paths it folds `A`–`Z` and represents each run of up to nine digits by a digit marker, its significant length and its significant digits. This gives numeric order without parsing an integer. Equal keys are resolved by the original ASCII spelling. Comparisons involving Unicode or a longer digit run use the original Foundation comparator and UTF-8 tie-break. The tree also splits ordinary parent and leaf names directly, tracks duplicate IDs in sets and skips the node-ID walk when there is no selection or expansion to restore.

The following figures compare the first revision and the follow-up in the **same** run on the same Mac. The procedure rotated both binary and fixture launch order and took 30 fresh-process observations per cell. The one-minute system load average was 25.17 shortly after the run. The earlier table was a separate measurement session.

| 2,000-file input | Median, first → follow-up | P95, first → follow-up | Maximum, first → follow-up | Calls above 50 ms, first → follow-up |
| --- | ---: | ---: | ---: | ---: |
| Original XCTest order | 22.21 → 17.42 ms | 56.51 → 38.20 ms | 351.19 → 43.77 ms | 4/30 → 0/30 |
| Deterministic permutation | 265.66 → 35.57 ms | 645.57 → 128.08 ms | 1,019.15 → 158.82 ms | 30/30 → 5/30 |

After the full hosted run exited, the same binaries and launch schedule produced the following independent repeat.

| 2,000-file input | Median, first → follow-up | P95, first → follow-up | Maximum, first → follow-up | Calls above 50 ms, first → follow-up |
| --- | ---: | ---: | ---: | ---: |
| Original XCTest order | 16.20 → 12.20 ms | 28.10 → 17.05 ms | 28.71 → 17.42 ms | 0/30 → 0/30 |
| Deterministic permutation | 84.13 → 20.81 ms | 128.18 → 34.43 ms | 262.02 → 36.38 ms | 30/30 → 0/30 |

The original budget test retains its 50 ms threshold. `testReconcileOrdersEveryPermutedPost` checks all 2,000 IDs in final order. `testPreparedPathOrderMatchesFoundationAndByteTies` compares ordered pairs against Foundation, covering all ASCII byte values, leading zeros, embedded digit runs, Unicode and long numbers. The timings above apply to the supplied ASCII fixture.
