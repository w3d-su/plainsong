import Foundation

/// One timed keystroke of the E9 typing-isolation probe.
struct ExportTypingSample: Codable, Equatable {
    /// Native insertion plus the scheduled public-view update: the existing §12 typing measure.
    let handlerMilliseconds: Double
    /// Main-thread CPU time over the same interval: less sensitive to other processes than
    /// wall time, and it still counts any export work that ran on the main thread inside it.
    let handlerCPUMilliseconds: Double
    /// How late the keystroke started against its fixed schedule. Main-actor work that runs
    /// between keystrokes, such as an export's own steps, shows up here.
    let startDelayMilliseconds: Double
    /// The export operation was still the active one when the keystroke started.
    let exportActive: Bool
    /// The synchronous insertion left the export's operation and task as they were: it did
    /// not supersede, cancel, or finish the export.
    let exportUntouched: Bool
}

/// One interleaved pair: typing with no export, and typing while one export runs. Odd rounds
/// run the export arm first, so drift in machine load reaches both arms alike.
struct ExportTypingRound: Codable {
    let index: Int
    let exportFirst: Bool
    let offsetMilliseconds: Double
    let withoutExport: [ExportTypingSample]
    let duringExport: [ExportTypingSample]
    let exportResult: String
    let loadBefore: Double
    let loadAfter: Double

    var activeDuringExport: [ExportTypingSample] {
        duringExport.filter(\.exportActive)
    }
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
}

struct ExportTypingInterval: Codable, Equatable {
    let estimate: Double
    let lower: Double
    let upper: Double
}

enum ExportTypingStatistics {
    static let frameBudget = 16.0
    /// G1: a regression larger than this cannot be excluded fails the gate.
    static let isolationMarginMilliseconds = 1.0
    /// G2: the export arm may exceed the budget at most this much more often than the
    /// no-export arm under the same load.
    static let overBudgetShareMargin = 0.01
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

    /// Pooled median of the active export samples minus the pooled median of the no-export
    /// samples, with a 95% percentile interval from a cluster bootstrap that resamples whole
    /// rounds, so samples that share a round's load are never treated as independent.
    static func medianDifference(
        _ rounds: [ExportTypingRound],
        resamples: Int = bootstrapResamples,
        seed: UInt64 = bootstrapSeed
    ) -> ExportTypingInterval {
        let withoutExport = rounds.map { $0.withoutExport.map(\.handlerMilliseconds) }
        let duringExport = rounds.map { $0.activeDuringExport.map(\.handlerMilliseconds) }
        let estimate = pooledDifference(
            withoutExport: withoutExport, duringExport: duringExport, rounds: Array(rounds.indices)
        )
        guard let estimate, !rounds.isEmpty else { return ExportTypingInterval(estimate: 0, lower: 0, upper: 0) }
        var generator = SplitMix64(seed: seed)
        var differences: [Double] = []
        differences.reserveCapacity(resamples)
        for _ in 0 ..< resamples {
            let chosen = (0 ..< rounds.count).map { _ in Int.random(in: 0 ..< rounds.count, using: &generator) }
            if let difference = pooledDifference(
                withoutExport: withoutExport, duringExport: duringExport, rounds: chosen
            ) {
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
        withoutExport: [[Double]],
        duringExport: [[Double]],
        rounds: [Int]
    ) -> Double? {
        let baseline = rounds.flatMap { withoutExport[$0] }.sorted()
        let active = rounds.flatMap { duringExport[$0] }.sorted()
        guard !baseline.isEmpty, !active.isEmpty else { return nil }
        return median(ofSorted: active) - median(ofSorted: baseline)
    }
}

/// The per-product result the probe prints and, in Release, gates on.
struct ExportTypingSummary: Codable {
    let product: String
    let configuration: String
    let roundCount: Int
    let roundsWithoutActiveSamples: Int
    let unfencedExportMilliseconds: Double
    let withoutExport: ExportTypingDistribution
    let duringExport: ExportTypingDistribution
    let withoutExportCPU: ExportTypingDistribution
    let duringExportCPU: ExportTypingDistribution
    let withoutExportStartDelay: ExportTypingDistribution
    let duringExportStartDelay: ExportTypingDistribution
    let medianDifference: ExportTypingInterval
    let untouchedViolations: Int
    let loadRange: [Double]
    /// G1: the interval excludes a median regression larger than the margin.
    let isolationPasses: Bool
    /// G2: the existing budget holds while export is active.
    let budgetPasses: Bool

    init(product: String, configuration: String, unfencedExportMilliseconds: Double, rounds: [ExportTypingRound]) {
        self.product = product
        self.configuration = configuration
        self.unfencedExportMilliseconds = unfencedExportMilliseconds
        roundCount = rounds.count
        roundsWithoutActiveSamples = rounds.filter(\.activeDuringExport.isEmpty).count
        let baseline = rounds.flatMap(\.withoutExport)
        let active = rounds.flatMap(\.activeDuringExport)
        withoutExport = ExportTypingDistribution(baseline.map(\.handlerMilliseconds))
        duringExport = ExportTypingDistribution(active.map(\.handlerMilliseconds))
        withoutExportCPU = ExportTypingDistribution(baseline.map(\.handlerCPUMilliseconds))
        duringExportCPU = ExportTypingDistribution(active.map(\.handlerCPUMilliseconds))
        withoutExportStartDelay = ExportTypingDistribution(baseline.map(\.startDelayMilliseconds))
        duringExportStartDelay = ExportTypingDistribution(active.map(\.startDelayMilliseconds))
        medianDifference = ExportTypingStatistics.medianDifference(rounds)
        untouchedViolations = rounds.flatMap(\.duringExport).filter { !$0.exportUntouched }.count
        let loads = rounds.flatMap { [$0.loadBefore, $0.loadAfter] }
        loadRange = [loads.min() ?? 0, loads.max() ?? 0]
        isolationPasses = duringExport.count > 0
            && medianDifference.upper <= ExportTypingStatistics.isolationMarginMilliseconds
        budgetPasses = duringExport.count > 0
            && duringExport.p95 < ExportTypingStatistics.frameBudget
            && duringExport.overBudgetShare
            <= withoutExport.overBudgetShare + ExportTypingStatistics.overBudgetShareMargin
    }

    var line: String {
        func describe(_ distribution: ExportTypingDistribution) -> String {
            String(
                format: "n=%d median %.3f p95 %.3f max %.3f >=16ms %.1f%%",
                distribution.count, distribution.median, distribution.p95, distribution.max,
                distribution.overBudgetShare * 100
            )
        }
        return """
        E9 TYPING \(product) \(configuration): unfenced export \(String(format: "%.0f", unfencedExportMilliseconds)) ms; \
        load \(String(format: "%.2f-%.2f", loadRange[0], loadRange[1]))
        E9 TYPING \(product) \(configuration) handler without export: \(describe(withoutExport))
        E9 TYPING \(product) \(configuration) handler during export: \(describe(duringExport))
        E9 TYPING \(product) \(configuration) main-thread CPU without export: \(describe(withoutExportCPU))
        E9 TYPING \(product) \(configuration) main-thread CPU during export: \(describe(duringExportCPU))
        E9 TYPING \(product) \(configuration) start delay without export: \(describe(withoutExportStartDelay))
        E9 TYPING \(product) \(configuration) start delay during export: \(describe(duringExportStartDelay))
        E9 TYPING \(product) \(configuration) median difference \
        \(String(format: "%+.3f [%+.3f, %+.3f]", medianDifference.estimate, medianDifference.lower, medianDifference.upper)) ms; \
        rounds without active samples \(roundsWithoutActiveSamples)/\(roundCount); \
        untouched violations \(untouchedViolations); \
        G1 \(isolationPasses ? "PASS" : "FAIL"); G2 \(budgetPasses ? "PASS" : "FAIL")
        """
    }
}

struct ExportTypingReport: Codable {
    let summary: ExportTypingSummary
    let rounds: [ExportTypingRound]
}

/// A seeded generator, so the bootstrap interval is reproducible from the printed samples.
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
