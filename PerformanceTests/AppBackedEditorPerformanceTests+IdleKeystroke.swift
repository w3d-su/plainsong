import AppKit
import Darwin
@testable import EditorKit
import MarkdownCore
@testable import Plainsong
import SwiftUI
import XCTest

/// Why the first keystroke after an idle pause is slower than the next ones
/// (`docs/perf/2026-11-18-keystroke-native-copy.md`). Each trial waits an idle time,
/// then types four keystrokes 80 ms apart, and records for every keystroke the hosted §12
/// measure, the main thread's CPU time, and its retired instructions and cycles. More
/// instructions on the first keystroke means the editor does more work after a pause;
/// the same instructions in more time means the CPU ran slower.
@MainActor
extension AppBackedEditorPerformanceTests {
    struct IdleKeystrokeSample: Codable {
        let trial: Int
        let idleMilliseconds: Double
        let position: Int
        let handlerMilliseconds: Double
        let cpuMilliseconds: Double
        let instructions: UInt64
        let cycles: UInt64
        /// Trimmer events (start, trim, trimmed, complete, …) since the previous keystroke.
        let trimmerEvents: [String]
    }

    func testFirstKeystrokeAfterAnIdlePause() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["PLAINSONG_RUN_IDLE_KEYSTROKE_PROBE"] == "1" else {
            throw XCTSkip("opt-in probe: TEST_RUNNER_PLAINSONG_RUN_IDLE_KEYSTROKE_PROBE=1")
        }
        let counters = try XCTUnwrap(ThreadCounters(), "thread_selfcounts is unavailable")
        let repetitions = Int(environment["PLAINSONG_IDLE_KEYSTROKE_REPETITIONS"] ?? "") ?? 6
        let fixture = environment["PLAINSONG_IDLE_KEYSTROKE_FIXTURE"] ?? "large-1mb.md"
        let source = try Self.fixtureText("Fixtures/\(fixture)")
        print("IDLE KEYSTROKE fixture \(fixture): \(source.utf8.count) UTF-8 bytes, \(source.utf16.count) UTF-16 units")
        let app = try await makeAppFixture(
            source: source,
            directoryPrefix: "IdleKeystroke",
            fileName: "large.md"
        )
        defer { tearDownAppFixture(app) }
        XCTAssertTrue(app.editor.window.makeFirstResponder(app.editor.textView))
        app.editor.textView.textSelection = NSRange(location: 0, length: 0)
        var trimmerEvents: [String] = []
        app.editor.coordinator.textElementCacheTrimmer.probeHandler = { event, _ in trimmerEvents.append(event) }
        defer { app.editor.coordinator.textElementCacheTrimmer.probeHandler = nil }

        // Warm up: a burst, so the first trial does not also pay first-use costs.
        for _ in 0 ..< 10 {
            _ = await measureHostedUpdate(in: app.editor) {
                app.editor.textView.insertText("a", replacementRange: .notFound)
            }
            cancelScheduledAppWork(in: app.appState)
            try await Task.sleep(for: .milliseconds(80))
        }

        // Profile mode: type continuously so an external `sample` sees mostly keystroke work.
        if let seconds = Double(environment["PLAINSONG_IDLE_KEYSTROKE_PROFILE_SECONDS"] ?? "") {
            print("IDLE KEYSTROKE profile start")
            let end = ContinuousClock.now + .seconds(seconds)
            while ContinuousClock.now < end {
                _ = await measureHostedUpdate(in: app.editor) {
                    app.editor.textView.insertText("a", replacementRange: .notFound)
                }
                cancelScheduledAppWork(in: app.appState)
                try await Task.sleep(for: .milliseconds(20))
            }
            print("IDLE KEYSTROKE profile end")
            return
        }

        let idles = [100.0, 300, 500, 700, 900, 1200, 2000, 4000]
        var generator = IdleProbeRandom(seed: 20_261_118)
        var samples: [IdleKeystrokeSample] = []
        var trial = 0
        for _ in 0 ..< repetitions {
            for idle in idles.shuffled(using: &generator) {
                try await Task.sleep(for: .milliseconds(idle))
                for position in 0 ..< 4 {
                    if position > 0 { try await Task.sleep(for: .milliseconds(80)) }
                    let events = trimmerEvents
                    trimmerEvents = []
                    let before = counters.read()
                    let cpuBefore = Self.idleProbeThreadCPUMilliseconds()
                    let handler = await measureHostedUpdate(in: app.editor) {
                        app.editor.textView.insertText("a", replacementRange: .notFound)
                    }
                    let cpu = Self.idleProbeThreadCPUMilliseconds() - cpuBefore
                    let after = counters.read()
                    XCTAssertGreaterThanOrEqual(after.instructions, before.instructions, "a counter read failed")
                    cancelScheduledAppWork(in: app.appState)
                    samples.append(IdleKeystrokeSample(
                        trial: trial,
                        idleMilliseconds: idle,
                        position: position,
                        handlerMilliseconds: handler,
                        cpuMilliseconds: cpu,
                        instructions: after.instructions &- before.instructions,
                        cycles: after.cycles &- before.cycles,
                        trimmerEvents: events
                    ))
                }
                trial += 1
            }
        }
        reportIdleKeystrokes(samples, idles: idles)
    }

    func reportIdleKeystrokes(_ samples: [IdleKeystrokeSample], idles: [Double]) {
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return 0 }
            let middle = sorted.count / 2
            return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        }
        for idle in idles {
            for positions in [[0], [1, 2, 3]] {
                let rows = samples.filter { $0.idleMilliseconds == idle && positions.contains($0.position) }
                let instructions = median(rows.map { Double($0.instructions) / 1e6 })
                let cycles = median(rows.map { Double($0.cycles) / 1e6 })
                let gigahertz = median(rows.map { Double($0.cycles) / max($0.cpuMilliseconds, 0.001) / 1e6 })
                let trims = rows.filter { $0.trimmerEvents.contains("trimmed") }.count
                print(String(
                    format: "IDLE KEYSTROKE idle %4.0f ms %@: n=%d handler %.2f cpu %.2f ms, instructions %.2f M, "
                        + "cycles %.2f M, %.2f GHz, trims before %d",
                    idle, positions == [0] ? "first " : "next 3", rows.count, median(rows.map(\.handlerMilliseconds)),
                    median(rows.map(\.cpuMilliseconds)), instructions, cycles, gigahertz, trims
                ))
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(samples) {
            print("IDLE KEYSTROKE JSON " + String(decoding: data, as: UTF8.self))
        }
    }
}

extension AppBackedEditorPerformanceTests {
    static func idleProbeThreadCPUMilliseconds() -> Double {
        var time = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
        return Double(time.tv_sec) * 1000 + Double(time.tv_nsec) / 1_000_000
    }
}

/// A seeded generator, so the trial order is reproducible.
struct IdleProbeRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

/// The calling thread's retired instructions and cycles, from the kernel's per-thread
/// counters (`thread_selfcounts`, looked up at run time; probe code only).
struct ThreadCounters {
    private typealias SelfCounts = @convention(c) (Int32, UnsafeMutableRawPointer, Int) -> Int32
    private let selfCounts: SelfCounts

    init?() {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "thread_selfcounts") else { return nil }
        selfCounts = unsafeBitCast(symbol, to: SelfCounts.self)
        guard read().instructions > 0 else { return nil }
    }

    func read() -> (instructions: UInt64, cycles: UInt64) {
        var buffer: (UInt64, UInt64) = (0, 0)
        let result = withUnsafeMutableBytes(of: &buffer) { selfCounts(1, $0.baseAddress!, 16) }
        return result == 0 ? buffer : (0, 0)
    }
}
