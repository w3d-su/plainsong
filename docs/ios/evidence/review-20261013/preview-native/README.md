# Native Preview review evidence — 2026-10-13

The full native iOS module gate remains **FAILED**. Preserve all failures; do not replace them with a green rerun or a skipped bundle case.

| Attempt | Source | Build | Runtime result |
| --- | --- | --- | --- |
| `empty-plan` | f619cf6 / exact207 inputs | Product scheme `PreviewKit`, exit0; empty TestConfigurations and no test bundle | Runner rejected, exit65; 0 compiled test cases /0 executed |
| `historical-full94` | f619cf6 / exact207 inputs | `PreviewKit-Package`, exit0; all94 named native test symbols present | xcodebuild65, xcresult94 executed:90 Passed/4 Failed/0 Skipped/0 missing; one of4 failures is a60s XCTest timeout |
| `candidate-hosted2` | 3fc31d4 / one test-helper delta | `PreviewKit-Package`, exit0 | xcodebuild65, xcresult2 executed:1 Passed/1 Failed/0 Skipped/0 missing |

The original46-case inventory incorrectly interpreted a conditional `import AppKit` as a file-wide macOS gate. The full selection already executed all94 cases. Its raw manifest and raw46-based gate are retained, alongside the corrected94 inventory, built-symbol proof and actual94 xcresult reconciliation. The48 valid additional platform-shared cases are not product defects.

The207 tracked copied inputs contain complete PreviewKit and MarkdownCore source/tests/manifests, committed preview HTML/JS/CSS/fonts, all tracked fixtures and the exact central xcresult parser. They were byte-verified before/after each run. Historical207 inputs are independently unchanged after candidate testing. Those historical207 inputs also match c1c250a Git blobs; this is a subset equivalence assertion, not an independent claim about all658 aggregate inputs or exact-head aggregate execution at f619cf6.

The root frozen inventory is13 API declaration files, plus6 extra scaffold/contract-test records verified against ios-c0-v1. They are not19 APIs and not all19 files were copied into the207-file test workspace. `frozen13-plus-c0-extra6-scope.json` lists the exact partition.

## Confirmed fixture defect and repaired scope

The first real-bundle assertion failures in the original94 run were copy-verification errors: `PreviewIOSHostedTests.swift:168` attempted missing copied paths `preview/index.html`, `preview/bundle.js` and `preview/fonts/...`. Foundation enumerated `/private/tmp/...` while the source root used `/tmp/...`; string-length slicing added an unintended `preview/` prefix. XCTest caught those Data-read errors inside assertion autoclosures, so the original test continued. No bundle-ready timeout was recorded in that94 run and the case finished1.769s; source control flow therefore indicates the later throwing DOM waits completed in that run, despite its failed byte-verification gate. The separate fixture-repair candidate reaches a new bundle-ready timeout; the two observations must not be conflated.

Native macOS Foundation reproduction performs a real64-file copy: the actual child index exists, the original relative calculation misses all64 files, and normalized root/file path components locate64 byte-identical files. A controlled missing copied resource throws and removes the temporary destination. This is fixture path/cleanup logic evidence, not iOS DOM acceptance.

Commit3fc31d4 changes only `Packages/PreviewKit/Tests/PreviewKitTests/PreviewIOSHostedTests.swift`: canonicalize both URLs, validate the component prefix, derive the relative path by components, read Data outside assertion autoclosures so missing files throw, and clean a partially verified copy on failure. The existing throwing8s polling, bounded2s JS callback, early controller teardown, production loader, CSP, JS, fonts, wire protocol and DOM assertions are unchanged. The other206 copied inputs are identical. Pinned SwiftFormat0.62.1 lint and patch whitespace checks passed; old authoring5826cb2 and Mac-proof f41ee1 branches remain unchanged.

## Remaining native blockers and next agent handoff

Use an L4 reviewer familiar with asynchronous UIKit/WebKit lifetimes and test evidence. Diagnose with test-only bounded telemetry before proposing a product patch.

| Case | Confirmed symptom | Open diagnosis |
| --- | --- | --- |
| `ExportHTMLHostedTests/testMDXPlaceholdersExportWithoutComponentExecution` | Original full94: ready and render wait failures at211, then stale-or-missing-render at71;12.048s. Four subsequent hosted export cases passed. | First/cold-load timing, resource access and bridge initialization are hypotheses. Later passes do not identify the cause. |
| `ExportHTMLOfflineTests/testEscapedLessThanURLSinksStayNeutralInTheReopenedDocument` | Original full94: `navigation.didFinish` assertion at205 failed;21.452s. | Why navigation completion is missing is not captured. Export content/CSS behavior is not proven to be the failure cause. |
| `ExportHTMLOfflineTests/testOfflineReopenRendersEmbeddedResourcesWithoutNetwork` | Original full94: same205 navigation failure, then XCTest60s allowance exceeded and host restart. | Source awaits WebKit JS without an operation deadline; navigation failure continues into JS/decode work. This is a confirmed harness bounding weakness, not proof of the initial navigation cause. |
| `PreviewIOSHostedTests/testBundledKitchenSinkAndMDXStayVisible` | Original alias copy failures were removed. Candidate now reaches real bundle load but throws `Timed out waiting for bundle ready` from the unchanged8s helper;9.594s. Synthetic bridge/latest-document case passed1.615s. | Real committed bundle readiness remains a v1 blocker. Fixture path repair alone does not close the hosted DOM gate. No kitchen-sink/MDX render assertions have passed on this candidate. |

The next diagnostic candidate should record file-URL/read-grant/root provenance; navigation start/finish/provisional-failure/failure; controller ready events and protocol version; bounded DOM readyState/location/bridge/resource observations; and immediate WebView cleanup. Reuse the throwing/bounded wait helper for export/offline harnesses without weakening assertions. Keep real64 resources byte-exact and capture every controlled change in a new candidate. Do not infer a cold-start, path-policy, entitlement, Xcode-beta or WebKit cause from missing callbacks or generic ExtensionKit termination warnings alone. Do not lengthen deadlines or rerun for green without evidence for the change.

## Runtime and memory scope

Both attempts used the task-owned A24A1CB9 destination and canonical lock, `-parallel-testing-enabled NO`, on-failure diagnostics, XCTest60s default/120s maximum allowance, and600s owned outer deadlines. Neither native attempt hit the outer or2GiB owned-host watchdog. Full94 required a host restart after one XCTest timeout; native PIDs14160/14877 are image/identity-verified. Candidate PID17976 is similarly verified. All test hosts exited naturally; terminal cleanup lists are empty. One requested native stack sample hit its own5s diagnostic deadline and is retained as a failed diagnostic; a later driver sample found its PID already exited. Do not label either as a test result.

Telemetry is one-second sampled ps RSS, with bounded vmmap snapshots and owned-image/PID/start-time proofs. Full native sampled host maxima254528/300176 KiB; candidate host187712 KiB. WebKit helper candidates were observed with unproven ownership and never signalled. Samples do not establish physical peak allocations or explain/exclude the earlier53.41GiB incident. No global simulator/service changes were made by this task. Raw test logs, process samples and metadata are retained; gzip files are reversible and each decompressed hash matches the original bytes.

`run-locations-and-scope.json` records exact commands' artifacts and local sealed xcresult paths. `index.json` records retained/original hashes and sizes. These runs do not accept physical input, Files/iCloud provider behavior, production composition, VoiceOver, signing/install or performance gates.
