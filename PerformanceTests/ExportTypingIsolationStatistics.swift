import Foundation

/// One timed keystroke of the E9 typing-isolation probe.
struct ExportTypingSample: Codable, Equatable {
    /// Index in its burst. Latency rises over the first keystrokes of a burst as work from
    /// earlier keystrokes lands, so arms are only compared at matching positions.
    let position: Int
    /// Scheduled start, since the arm began.
    let scheduledMilliseconds: Double
    /// Native insertion plus the scheduled public-view update: the existing §12 typing measure.
    let handlerMilliseconds: Double
    /// Main-thread CPU time over the same interval: less sensitive to other processes than
    /// wall time, and it still counts any export work that ran on the main thread inside it.
    let handlerCPUMilliseconds: Double
    /// How late the keystroke started against its schedule: main-actor work that held the
    /// thread when the keystroke was due.
    let startDelayMilliseconds: Double
    /// The export operation was still the active one when the keystroke started.
    let exportActiveAtStart: Bool
    /// The synchronous insertion left the export's operation and task as they were: it did
    /// not supersede, cancel, or finish the export.
    let exportUntouched: Bool
    /// Scheduled before the export finished, including a keystroke that the export's last
    /// synchronous step (fence, write, teardown) delayed. Set once the arm ends.
    var duringExport = false

    var eventToUpdateMilliseconds: Double {
        startDelayMilliseconds + handlerMilliseconds
    }
}

/// One interleaved pair: a typing burst with no export, and a burst while one export runs.
struct ExportTypingRound: Codable {
    let index: Int
    let exportFirst: Bool
    let offsetMilliseconds: Double
    let withoutExport: [ExportTypingSample]
    let exportArm: [ExportTypingSample]
    /// Since the export arm began; nil only if the operation never reported a result.
    let exportFinishedMilliseconds: Double?
    let exportResult: String
    /// The first keystroke ran while the export was active, so the export must have stopped
    /// with `.documentChanged` and written nothing; `fenceHeld` records whether it did.
    let fenceChecked: Bool
    let fenceHeld: Bool
    let loadBefore: Double
    let loadAfter: Double

    var duringExport: [ExportTypingSample] {
        exportArm.filter(\.duringExport)
    }
}

/// Every stretch of main run loop work in one window with no typing: either one warm export
/// run to completion, or an idle window of the same length.
struct ExportBusyWindow: Codable {
    struct Slice: Codable {
        let startMilliseconds: Double
        let wallMilliseconds: Double
        let cpuMilliseconds: Double
    }

    let kind: String
    let durationMilliseconds: Double
    let slices: [Slice]
}

/// Count, median, nearest-rank p95, maximum, and the share at or over the 16 ms budget.
/// An empty input reports zeros with a count of 0, because JSON cannot carry NaN.
struct ExportTypingDistribution: Codable, Equatable {
    let count: Int
    let median: Double
    let p95: Double
    let max: Double
    let overBudgetShare: Double

    init(_ values: [Double], budget: Double = ExportTypingStatistics.frameBudget) {
        let sorted = values.sorted()
        count = sorted.count
        median = ExportTypingStatistics.median(ofSorted: sorted)
        p95 = ExportTypingStatistics.nearestRank(0.95, ofSorted: sorted)
        max = sorted.last ?? 0
        overBudgetShare = sorted.isEmpty ? 0 : Double(sorted.filter { $0 >= budget }.count) / Double(sorted.count)
    }

    var line: String {
        String(
            format: "n=%d median %.3f p95 %.3f max %.3f >=16ms %.1f%%",
            count, median, p95, max, overBudgetShare * 100
        )
    }
}

struct ExportTypingInterval: Codable, Equatable {
    let estimate: Double
    let lower: Double
    let upper: Double
}

/// Keystrokes `0 ..< 10` of a burst, and `10...` once the burst has settled.
enum ExportTypingStratum: String, Codable, CaseIterable {
    case burstStart
    case sustained

    static let sustainedFromPosition = 10

    func contains(_ position: Int) -> Bool {
        switch self {
        case .burstStart: position < Self.sustainedFromPosition
        case .sustained: position >= Self.sustainedFromPosition
        }
    }
}

/// Handler time with and without an active export at matching burst positions.
struct ExportTypingComparison: Codable {
    let stratum: ExportTypingStratum
    let withoutExport: ExportTypingDistribution
    let duringExport: ExportTypingDistribution
    let roundsWithDuringSamples: Int
    let medianDifference: ExportTypingInterval
    /// At least `minimumCoveredRounds` rounds contributed keystrokes during export.
    let covered: Bool
    /// G1 for this stratum.
    let isolationPasses: Bool
    /// G2's share clause for this stratum.
    let shareWithinMargin: Bool

    init(stratum: ExportTypingStratum, rounds: [ExportTypingRound]) {
        self.stratum = stratum
        let baseline = rounds.map { $0.withoutExport.filter { stratum.contains($0.position) } }
        let during = rounds.map { $0.duringExport.filter { stratum.contains($0.position) } }
        withoutExport = ExportTypingDistribution(baseline.flatMap { $0.map(\.handlerMilliseconds) })
        duringExport = ExportTypingDistribution(during.flatMap { $0.map(\.handlerMilliseconds) })
        roundsWithDuringSamples = during.filter { !$0.isEmpty }.count
        medianDifference = ExportTypingStatistics.medianDifference(
            withoutExport: baseline.map { $0.map(\.handlerMilliseconds) },
            duringExport: during.map { $0.map(\.handlerMilliseconds) }
        )
        covered = roundsWithDuringSamples >= ExportTypingStatistics.minimumCoveredRounds
        isolationPasses = covered && medianDifference.upper <= ExportTypingStatistics.isolationMarginMilliseconds
        shareWithinMargin = duringExport.overBudgetShare
            <= withoutExport.overBudgetShare + ExportTypingStatistics.overBudgetShareMargin
    }
}

/// Main run loop slices in the warm-export windows against the idle windows.
struct ExportBusySummary: Codable {
    let windows: Int
    let durationMilliseconds: Double
    let slices: Int
    let maxWallMilliseconds: Double
    let over16: Int
    let over50: Int
    let over100: Int
    let totalWallMilliseconds: Double
    let totalCPUMilliseconds: Double
    /// The five longest slices as wall/CPU ms at their start, ms since their window began.
    let longest: [String]

    init(_ windows: [ExportBusyWindow]) {
        let slices = windows.flatMap(\.slices)
        let walls = slices.map(\.wallMilliseconds)
        self.windows = windows.count
        durationMilliseconds = windows.map(\.durationMilliseconds).reduce(0, +)
        self.slices = slices.count
        maxWallMilliseconds = walls.max() ?? 0
        over16 = walls.filter { $0 >= 16 }.count
        over50 = walls.filter { $0 >= 50 }.count
        over100 = walls.filter { $0 >= 100 }.count
        totalWallMilliseconds = walls.reduce(0, +)
        totalCPUMilliseconds = slices.map(\.cpuMilliseconds).reduce(0, +)
        longest = slices.sorted { $0.wallMilliseconds > $1.wallMilliseconds }.prefix(5).map {
            String(format: "%.1f/%.1f@%.0f", $0.wallMilliseconds, $0.cpuMilliseconds, $0.startMilliseconds)
        }
    }

    var line: String {
        String(
            format: "windows %d (%.0f ms) slices %d max %.1f >=16 %d >=50 %d >=100 %d busy %.0f ms cpu %.0f ms",
            windows, durationMilliseconds, slices, maxWallMilliseconds, over16, over50, over100,
            totalWallMilliseconds, totalCPUMilliseconds
        ) + " longest " + longest.joined(separator: " ")
    }
}

enum ExportTypingStatistics {
    static let frameBudget = 16.0
    /// G1: a regression larger than this that cannot be excluded fails the gate.
    static let isolationMarginMilliseconds = 1.0
    /// G2: the export arm may exceed the budget at most this much more often than the
    /// no-export arm at the same burst positions.
    static let overBudgetShareMargin = 0.01
    /// G0/G1 coverage: fewer rounds than this cannot support an interval over rounds.
    static let minimumCoveredRounds = 4
    /// G0 coverage: share of rounds whose export arm must have keystrokes during export.
    static let minimumRoundsWithDuringSamples = 0.75
    static let bootstrapResamples = 10000
    static let bootstrapSeed: UInt64 = 20_261_118

    static func median(ofSorted sorted: [Double]) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    /// Nearest-rank percentile: the smallest value with at least `fraction` of the samples
    /// at or below it.
    static func nearestRank(_ fraction: Double, ofSorted sorted: [Double]) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }

    /// Pooled median during export minus pooled median without, with a 95% percentile
    /// interval from a cluster bootstrap that resamples whole rounds, so samples that share
    /// a round's load are never treated as independent. A resample without both arms is
    /// redrawn, so every interval rests on `resamples` usable draws.
    static func medianDifference(
        withoutExport: [[Double]],
        duringExport: [[Double]],
        resamples: Int = bootstrapResamples,
        seed: UInt64 = bootstrapSeed
    ) -> ExportTypingInterval {
        let rounds = Array(withoutExport.indices)
        guard let estimate = pooledDifference(withoutExport, duringExport, rounds) else {
            return ExportTypingInterval(estimate: 0, lower: 0, upper: 0)
        }
        var generator = SplitMix64(seed: seed)
        var differences: [Double] = []
        differences.reserveCapacity(resamples)
        var draws = 0
        while differences.count < resamples, draws < resamples * 20 {
            draws += 1
            let chosen = rounds.map { _ in Int.random(in: 0 ..< rounds.count, using: &generator) }
            if let difference = pooledDifference(withoutExport, duringExport, chosen) {
                differences.append(difference)
            }
        }
        differences.sort()
        return ExportTypingInterval(
            estimate: estimate,
            lower: nearestRank(0.025, ofSorted: differences),
            upper: nearestRank(0.975, ofSorted: differences)
        )
    }

    private static func pooledDifference(
        _ withoutExport: [[Double]],
        _ duringExport: [[Double]],
        _ rounds: [Int]
    ) -> Double? {
        let baseline = rounds.flatMap { withoutExport[$0] }.sorted()
        let during = rounds.flatMap { duringExport[$0] }.sorted()
        guard !baseline.isEmpty, !during.isEmpty else { return nil }
        return median(ofSorted: during) - median(ofSorted: baseline)
    }
}

/// A seeded generator, so the bootstrap interval and keystroke jitter are reproducible.
struct SplitMix64: RandomNumberGenerator {
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
