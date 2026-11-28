import AppKit
import Darwin
@testable import EditorKit
import MarkdownCore
@testable import Plainsong
import SwiftUI
import XCTest

/// Why the first keystroke after an idle pause is slower than the next ones
/// (`docs/perf/2026-11-18-keystroke-native-copy.md`,
/// `docs/perf/2026-11-28-idle-first-keystroke.md`). Each trial waits an idle time, then
/// types `…_KEYSTROKES` keystrokes 80 ms apart, and records for every keystroke the hosted
/// §12 measure, the main thread's CPU time, its retired instructions and cycles on each
/// core type, its user and system time, and the process's page faults. More instructions
/// on the first keystroke means the editor does more work after a pause; the same
/// instructions in more cycles at the same clock means cold caches; fewer cycles per
/// millisecond means a lower clock; cycles on the efficiency cores mean the thread ran there.
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
        /// Per performance level, level 0 being the performance cores.
        let levels: [ThreadCounters.Level]
        let faults: Int
        let pageins: Int
        let startCPU: Int
        let endCPU: Int
        let qualityOfService: UInt32
        /// The trial's arm (`IdleKeystrokeArm`) and, on its first keystroke, the faults the
        /// arm's touch took after the idle.
        let arm: String
        let armFaults: Int
        /// Faults and time inside `insertText`, before the SwiftUI settle.
        let insertFaults: Int
        let insertMilliseconds: Double
        /// Memory at the end of the previous trial, before the idle, and around this keystroke.
        let memoryBeforeIdle: TaskMemorySnapshot?
        let memoryBefore: TaskMemorySnapshot
        let memoryAfter: TaskMemorySnapshot
        /// Pages per VM region tag before and after a trial's first keystroke.
        let regionsBefore: [String: VMRegionCensus.Pages]?
        let regionsAfter: [String: VMRegionCensus.Pages]?
        /// Trimmer events (start, trim, trimmed, complete, …) since the previous keystroke.
        let trimmerEvents: [String]
    }

    struct IdleKeystrokeOptions {
        let idles: [Double]
        let keystrokes: Int
        let repetitions: Int
        /// Arms, each run at every idle in every repetition, in seeded random order.
        let arms: [IdleKeystrokeArm]

        init(environment: [String: String]) {
            idles = (environment["PLAINSONG_IDLE_KEYSTROKE_IDLES_MS"] ?? "100,1000,2000,5000,10000,20000")
                .split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            keystrokes = max(Int(environment["PLAINSONG_IDLE_KEYSTROKE_KEYSTROKES"] ?? "") ?? 10, 2)
            repetitions = Int(environment["PLAINSONG_IDLE_KEYSTROKE_REPETITIONS"] ?? "") ?? 6
            arms = (environment["PLAINSONG_IDLE_KEYSTROKE_ARMS"] ?? "none")
                .split(separator: ",").compactMap { IdleKeystrokeArm(rawValue: String($0)) }
        }
    }

    func testFirstKeystrokeAfterAnIdlePause() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["PLAINSONG_RUN_IDLE_KEYSTROKE_PROBE"] == "1" else {
            throw XCTSkip("opt-in probe: TEST_RUNNER_PLAINSONG_RUN_IDLE_KEYSTROKE_PROBE=1")
        }
        let counters = try XCTUnwrap(ThreadCounters(), "thread_selfcounts is unavailable")
        let options = IdleKeystrokeOptions(environment: environment)
        let fixture = environment["PLAINSONG_IDLE_KEYSTROKE_FIXTURE"] ?? "large-1mb.md"
        let source = try Self.fixtureText("Fixtures/\(fixture)")
        print("IDLE KEYSTROKE fixture \(fixture): \(source.utf8.count) UTF-8 bytes, \(source.utf16.count) UTF-16 units")
        print("IDLE KEYSTROKE options idles \(options.idles) keystrokes \(options.keystrokes) "
            + "repetitions \(options.repetitions) arms \(options.arms.map(\.rawValue)) "
            + "load \(Self.idleProbeLoad())")
        let app = try await makeAppFixture(
            source: source,
            directoryPrefix: "IdleKeystroke",
            fileName: "large.md"
        )
        defer { tearDownAppFixture(app) }
        XCTAssertTrue(app.editor.window.makeFirstResponder(app.editor.textView))
        app.editor.textView.textSelection = NSRange(location: 0, length: 0)
        print("IDLE KEYSTROKE host active \(NSApp.isActive), main thread QoS \(qos_class_self().rawValue)")
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

        var generator = IdleProbeRandom(seed: 20_261_118)
        var samples: [IdleKeystrokeSample] = []
        var trial = 0
        let heapAttribution = environment["PLAINSONG_IDLE_KEYSTROKE_HEAP"] == "1"
        var decompressedPages: [UInt] = []
        let trials = options.idles.flatMap { idle in options.arms.map { (idle, $0) } }
        for repetition in 0 ..< options.repetitions {
            for (idle, arm) in trials.shuffled(using: &generator) {
                let memoryBeforeIdle = TaskMemorySnapshot.read()
                if arm.walksDuringIdle {
                    let end = ContinuousClock.now + .milliseconds(idle)
                    while ContinuousClock.now + .milliseconds(500) < end {
                        try await Task.sleep(for: .milliseconds(500))
                        IdleProbeHeapWarmer.walk(read: arm == .keepWarm)
                    }
                    try await Task.sleep(until: end)
                } else {
                    try await Task.sleep(for: .milliseconds(idle))
                }
                let armFaultsBefore = TaskFaultCounters.read().faults
                arm.touch(app)
                let armFaults = TaskFaultCounters.read().faults - armFaultsBefore
                for position in 0 ..< options.keystrokes {
                    if position > 0 { try await Task.sleep(for: .milliseconds(80)) }
                    let events = trimmerEvents
                    trimmerEvents = []
                    let memoryBefore = TaskMemorySnapshot.read()
                    let regionsBefore = position == 0 ? VMRegionCensus.read() : nil
                    let compressedPages = position == 0 && heapAttribution ? CompressedPageAttribution.pagedOut() : []
                    var insertFaults = 0
                    var insertMilliseconds = 0.0
                    let faultsBefore = TaskFaultCounters.read()
                    let startCPU = IdleProbeProcessor.currentCPU()
                    let levelsBefore = counters.readLevels()
                    let before = counters.read()
                    let cpuBefore = Self.idleProbeThreadCPUMilliseconds()
                    let handler = await measureHostedUpdate(in: app.editor) {
                        let insertStart = DispatchTime.now().uptimeNanoseconds
                        app.editor.textView.insertText("a", replacementRange: .notFound)
                        insertMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - insertStart) / 1_000_000
                        insertFaults = TaskFaultCounters.read().faults - faultsBefore.faults
                    }
                    let cpu = Self.idleProbeThreadCPUMilliseconds() - cpuBefore
                    let after = counters.read()
                    let levelsAfter = counters.readLevels()
                    let endCPU = IdleProbeProcessor.currentCPU()
                    let faultsAfter = TaskFaultCounters.read()
                    let memoryAfter = TaskMemorySnapshot.read()
                    let regionsAfter = position == 0 ? VMRegionCensus.read() : nil
                    if !compressedPages.isEmpty {
                        let stillCompressed = CompressedPageAttribution.stillPagedOut(compressedPages)
                        decompressedPages = compressedPages.filter { !stillCompressed.contains($0) }
                    }
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
                        levels: ThreadCounters.difference(levelsAfter, levelsBefore),
                        faults: faultsAfter.faults - faultsBefore.faults,
                        pageins: faultsAfter.pageins - faultsBefore.pageins,
                        startCPU: startCPU,
                        endCPU: endCPU,
                        qualityOfService: qos_class_self().rawValue,
                        arm: arm.rawValue,
                        armFaults: position == 0 ? armFaults : 0,
                        insertFaults: insertFaults,
                        insertMilliseconds: insertMilliseconds,
                        memoryBeforeIdle: position == 0 ? memoryBeforeIdle : nil,
                        memoryBefore: memoryBefore,
                        memoryAfter: memoryAfter,
                        regionsBefore: regionsBefore,
                        regionsAfter: regionsAfter,
                        trimmerEvents: events
                    ))
                }
                if heapAttribution {
                    let owners = CompressedPageAttribution.attribute(pages: decompressedPages)
                    let total = owners.reduce(0) { $0 + $1.bytes }
                    print("IDLE KEYSTROKE HEAP trial \(trial) idle \(Int(idle)) ms: "
                        + "\(decompressedPages.count) malloc pages decompressed, \(total / 1024) KiB attributed; "
                        + owners.prefix(12).map { "\($0.owner) \($0.bytes / 1024) KiB/\($0.blocks)" }
                        .joined(separator: ", "))
                    decompressedPages = []
                }
                trial += 1
            }
            print("IDLE KEYSTROKE repetition \(repetition + 1)/\(options.repetitions) load \(Self.idleProbeLoad())")
        }
        reportIdleKeystrokes(samples, idles: options.idles)
    }

    func reportIdleKeystrokes(_ samples: [IdleKeystrokeSample], idles: [Double]) {
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return 0 }
            let middle = sorted.count / 2
            return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        }
        let arms = IdleKeystrokeArm.allCases.map(\.rawValue).filter { arm in samples.contains { $0.arm == arm } }
        for idle in idles {
            for arm in arms {
                for first in [true, false] {
                    let rows = samples.filter {
                        $0.idleMilliseconds == idle && ($0.position == 0) == first && $0.arm == arm
                    }
                    guard !rows.isEmpty else { continue }
                    let performanceGigahertz = rows.compactMap(\.levels.first).map {
                        Double($0.cycles) / max($0.userMilliseconds + $0.systemMilliseconds, 0.001) / 1e6
                    }
                    print(String(
                        format: "IDLE KEYSTROKE idle %5.0f ms %@ %@: n=%d handler %.2f cpu %.2f ms, "
                            + "instructions %.2f M, cycles %.2f M (E %.2f M), P %.2f GHz, system %.2f ms, faults %.0f",
                        idle, arm, first ? "first " : "others", rows.count, median(rows.map(\.handlerMilliseconds)),
                        median(rows.map(\.cpuMilliseconds)), median(rows.map { Double($0.instructions) / 1e6 }),
                        median(rows.map { Double($0.cycles) / 1e6 }),
                        median(rows.map { Double($0.levels.dropFirst().reduce(0) { $0 + $1.cycles }) / 1e6 }),
                        median(performanceGigahertz),
                        median(rows.map { $0.levels.reduce(0) { $0 + $1.systemMilliseconds } }),
                        median(rows.map { Double($0.faults) })
                    ))
                }
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
    nonisolated static func idleProbeLoad() -> String {
        var load = [Double](repeating: 0, count: 3)
        return getloadavg(&load, 3) == 3 ? String(format: "%.2f %.2f %.2f", load[0], load[1], load[2]) : "unknown"
    }

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
