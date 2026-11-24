# iOS keystroke publish: native source copy against the bridged storage string

- Date: 2026-11-23
- Commit: after = #289 at `8f7b8dfa` (`IOSSourceEditorController.publishCurrentText` with the
  write fence and `nativeSourceText()`); before = #282 at `5522627b` (`plainText()` and an
  `NSString` literal compare). `ExactSourceText.swift` is byte-identical in both.
- Environment: macOS 27.0 (26A428), Xcode 27.0 (27A5194q), Swift 6.4, Apple M1 Pro
  (MacBookPro18,3). Standalone benchmark built with `swiftc -O`. One-minute load 8.8–10.1
  from other processes; retired instructions are compared, wall time only for scale.
- Fixture: `Fixtures/kitchen-sink.md` (3.4 KB), `perf-100kb.md`, `perf-500kb.md`,
  `large-1mb.md`, and 1 MiB of generated Traditional Chinese Markdown (headings, emphasis,
  links, lists; 1,048,900 UTF-8 bytes, 422,028 UTF-16 units). Budget: `agent.md` §12 typing
  < 16 ms and no O(document) work per keystroke on the main thread beyond the one native copy.
- Procedure: the benchmark below, `bench 41 <fixtures…>`, run three times. Each round inserts
  one character in the middle of the document (alternately `a` and `字`) into two identical
  `NSTextStorage`s, then times the before and after publish step on its own storage,
  alternating which side runs first. 5 warm-up rounds, 41 measured, medians. Counters are
  `proc_pid_rusage` `ri_instructions`/`ri_cycles` and thread CPU time.
- Result: the change lowers the per-keystroke cost it touches by 4.0x (1 MiB Chinese) to
  9.1x (1 MiB ASCII) in retired instructions. The after path is 1.30 ms per keystroke at
  1 MiB ASCII and 1.73 ms at 1 MiB Chinese. Pass, with the limits below.

## What is measured

The iOS editor runs `publishCurrentText()` from `textViewDidChange` on every keystroke.

Before (#282):

1. `plainText()` bridges `textStorage.string`.
2. `ExactSourceFragment.matches` compares the result with the session text as an `NSString`
   literal compare.
3. `DocumentSession.replaceText` repeats that check through `ExactSourceText.matches`.
4. `replaceText` compares the saved text with the new text to set `isDirty`.

The session text is then the bridged string. `ExactSourceText.matches` has a fast path for
native strings only, so each of those comparisons falls back to `NSString` and walks the
document up to the edit.

After (#289):

1. `installation.canWrite` is read: a stored `Bool`.
2. `nativeSourceText()` makes one `CFStringGetBytes` copy into a native UTF-8 string
   (`ExactSourceText.nativeCopy`, `docs/perf/2026-11-18-keystroke-native-copy.md`).
3. The same three comparisons now compare two native strings. They compare byte counts
   first, then `memcmp`.

The benchmark also times one downstream consumer that reads the published text on every
keystroke: `IOSAuthoringController+Frontmatter` compares its accepted text with each editor
snapshot's `document.text`. That check is the same code before and after. Only the kind of
string it receives changes.

Not modelled, because it is the same on both sides: the statistics scheduling that follows
the publish, and the snapshot emission.

## Result

Medians of run 1. Runs 2 and 3 are within 0.1% in instructions and 5% in CPU time.

| Document | Publish, before | Publish, after | Frontmatter check, before → after | Total instructions, before → after |
|---|---|---|---|---|
| 3.4 KB | 0.035 ms, 0.59 M | 0.006 ms, 0.10 M | 0.21 → 0.01 M | 0.80 → 0.11 M |
| 100 KB | 0.839 ms, 15.24 M | 0.113 ms, 2.28 M | 5.29 → 0.01 M | 20.53 → 2.28 M |
| 500 KB | 4.642 ms, 83.54 M | 0.639 ms, 12.43 M | 28.98 → 0.01 M | 112.52 → 12.44 M |
| 1 MiB ASCII | 9.707 ms, 174.55 M | 1.296 ms, 25.96 M | 60.54 → 0.01 M | 235.08 → 25.97 M |
| 1 MiB Chinese | 5.138 ms, 83.02 M | 1.730 ms, 27.00 M | 24.37 → 0.01 M | 107.40 → 27.01 M |

The total CPU time per keystroke falls:

| Document | Before | After |
|---|---|---|
| 1 MiB ASCII | 13.19 ms | 1.30 ms |
| 1 MiB Chinese | 6.55 ms | 1.73 ms |

The after cost is the native copy alone: about 25 instructions per UTF-8 byte. That matches
the macOS measurement of the same function. The comparisons that follow cost nothing
measurable, because an insertion changes the byte count. A same-length replacement would
`memcmp` up to the edit.

Only mid-document edits were measured. The before cost depends on where the caret is,
because the `NSString` compares walk to the first difference. Typing near the end of a
document should therefore cost more than the numbers above, and typing near the start less.
The after cost does not depend on the caret.

## Limits

This is a Mac measurement of the code the change touches. It is not keystroke-to-screen
latency on a device.

- It runs on an M1 Pro, not an iPhone or iPad, and uses AppKit's `NSTextStorage`, not the
  storage of a `UITextView`.
- It does not include TextKit layout, highlighting, the snapshot observers or SwiftUI.
- Device numbers come from the in-app Performance Probe (`docs/ios/performance-probe.md`),
  which needs a signed device build. That is not available here, so the device check stays
  with the owner.

The measurement shows the change removes per-keystroke main-thread work and adds none.
Whatever else a keystroke costs on a device is the same before and after.

<details>
<summary>Benchmark source (<code>main.swift</code>; build with
<code>swiftc -O -o bench main.swift Packages/MarkdownCore/Sources/MarkdownCore/ExactSourceText.swift</code>)</summary>

```swift
import AppKit
import Darwin
import Foundation

final class SessionModel {
    var text: String
    var savedText: String?
    var isDirty = false
    var version = 0

    init(text: String) {
        self.text = text
        savedText = text
    }

    // DocumentSession.replaceText, minus statistics (refreshStatistics: false) and the stream.
    func replaceText(_ newText: String) {
        guard !ExactSourceText.matches(newText, text) else { return }
        text = newText
        let newIsDirty = savedText.map { !ExactSourceText.matches($0, newText) } ?? true
        if isDirty != newIsDirty { isDirty = newIsDirty }
        version += 1
    }
}

// #282 head: plainText() + ExactSourceFragment.matches as an NSString literal compare.
@inline(never) func publishBefore(_ storage: NSTextStorage, _ session: SessionModel) {
    let current = storage.string
    guard (current as NSString).compare(session.text, options: .literal) != .orderedSame else { return }
    session.replaceText(current)
}

// #289: canWrite (a stored Bool) + nativeSourceText() + ExactSourceFragment = ExactSourceText.matches.
@inline(never) func publishAfter(_ storage: NSTextStorage, _ session: SessionModel, canWrite: Bool) {
    guard canWrite else { return }
    let current = ExactSourceText.nativeCopy(of: storage.mutableString) ?? storage.string
    guard !ExactSourceText.matches(current, session.text) else { return }
    session.replaceText(current)
}

// IOSAuthoringController+Frontmatter: compares the accepted text with each snapshot's text.
@inline(never) func frontmatterSnapshotCheck(_ accepted: inout String, _ snapshotText: String) -> Bool {
    let changed = !ExactSourceText.matches(accepted, snapshotText)
    if changed { accepted = snapshotText }
    return changed
}

struct Counters {
    var instructions: UInt64
    var cycles: UInt64
    var cpuNanoseconds: UInt64
}

func counters() -> Counters {
    var info = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
        }
    }
    precondition(result == 0)
    return Counters(
        instructions: info.ri_instructions,
        cycles: info.ri_cycles,
        cpuNanoseconds: clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    )
}

func delta(_ a: Counters, _ b: Counters) -> Counters {
    Counters(instructions: b.instructions - a.instructions, cycles: b.cycles - a.cycles,
             cpuNanoseconds: b.cpuNanoseconds - a.cpuNanoseconds)
}

func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    return sorted[sorted.count / 2]
}

struct Samples {
    var publish: [Counters] = []
    var frontmatter: [Counters] = []
}

func run(name: String, text: String, rounds: Int, warmup: Int) {
    let storageBefore = NSTextStorage(string: text)
    let storageAfter = NSTextStorage(string: text)
    // The session opens with the file's native text, as after a load.
    let sessionBefore = SessionModel(text: String(decoding: Array(text.utf8), as: UTF8.self))
    let sessionAfter = SessionModel(text: String(decoding: Array(text.utf8), as: UTF8.self))
    var acceptedBefore = sessionBefore.text
    var acceptedAfter = sessionAfter.text
    var before = Samples()
    var after = Samples()

    for round in 0 ..< (warmup + rounds) {
        let location = storageBefore.length / 2
        let character = round % 2 == 0 ? "a" : "字"
        storageBefore.replaceCharacters(in: NSRange(location: location, length: 0), with: character)
        storageAfter.replaceCharacters(in: NSRange(location: location, length: 0), with: character)

        func measureBefore() {
            let t0 = counters()
            publishBefore(storageBefore, sessionBefore)
            let t1 = counters()
            _ = frontmatterSnapshotCheck(&acceptedBefore, sessionBefore.text)
            let t2 = counters()
            if round >= warmup {
                before.publish.append(delta(t0, t1))
                before.frontmatter.append(delta(t1, t2))
            }
        }
        func measureAfter() {
            let t0 = counters()
            publishAfter(storageAfter, sessionAfter, canWrite: true)
            let t1 = counters()
            _ = frontmatterSnapshotCheck(&acceptedAfter, sessionAfter.text)
            let t2 = counters()
            if round >= warmup {
                after.publish.append(delta(t0, t1))
                after.frontmatter.append(delta(t1, t2))
            }
        }
        // Alternate which side runs first, so neither always gets the warmer cache.
        if round % 2 == 0 { measureBefore(); measureAfter() } else { measureAfter(); measureBefore() }
    }

    precondition(sessionBefore.version == warmup + rounds && sessionAfter.version == warmup + rounds)
    precondition(ExactSourceText.matches(sessionAfter.text, sessionBefore.text))

    func row(_ label: String, _ samples: [Counters]) -> String {
        let ms = median(samples.map { Double($0.cpuNanoseconds) / 1e6 })
        let minstr = median(samples.map { Double($0.instructions) / 1e6 })
        let mcyc = median(samples.map { Double($0.cycles) / 1e6 })
        return String(format: "%@ | %@ | %.3f ms | %.2f M instr | %.2f M cycles", name, label, ms, minstr, mcyc)
    }
    print(row("before publish", before.publish))
    print(row("after publish", after.publish))
    print(row("before frontmatter check", before.frontmatter))
    print(row("after frontmatter check", after.frontmatter))
    let beforeTotal = zip(before.publish, before.frontmatter).map {
        Counters(instructions: $0.instructions + $1.instructions, cycles: $0.cycles + $1.cycles,
                 cpuNanoseconds: $0.cpuNanoseconds + $1.cpuNanoseconds)
    }
    let afterTotal = zip(after.publish, after.frontmatter).map {
        Counters(instructions: $0.instructions + $1.instructions, cycles: $0.cycles + $1.cycles,
                 cpuNanoseconds: $0.cpuNanoseconds + $1.cpuNanoseconds)
    }
    print(row("before total", beforeTotal))
    print(row("after total", afterTotal))
}

let arguments = CommandLine.arguments
let rounds = Int(arguments[1]) ?? 41
for path in arguments.dropFirst(2) {
    let text = try! String(contentsOfFile: path, encoding: .utf8)
    let name = "\((path as NSString).lastPathComponent) (\(text.utf8.count) B, \((text as NSString).length) UTF-16)"
    run(name: name, text: text, rounds: rounds, warmup: 5)
}
```

The Chinese fixture repeats this block to 1 MiB of UTF-8:

```markdown
## 第一章：注音輸入的測試段落

這是一段用來量測編輯器打字效能的繁體中文文字，內容包含**粗體**、*斜體*、`行內程式碼`與[連結](./其他文章.md)。每一行都夠長，讓轉碼與比較都走過真正的多位元組字元，而不是只有 ASCII。

- 清單項目一：部落格文章的草稿
- 清單項目二：前言與摘要
- [ ] 待辦事項：校對標點符號
```

</details>
