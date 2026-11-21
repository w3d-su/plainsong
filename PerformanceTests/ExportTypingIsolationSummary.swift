import Foundation

/// The per-product result the E9 typing probe prints and, in Release, gates on. The gates
/// are defined in `docs/perf/2026-11-18-export-e9-typing-isolation.md`.
struct ExportTypingSummary: Codable {
    let product: String
    let configuration: String
    let roundCount: Int
    let warmExportMilliseconds: Double
    let roundsWithDuringSamples: Int
    let fencedRounds: Int
    let fenceFailures: Int
    let untouchedViolations: Int
    let comparisons: [ExportTypingComparison]
    /// Keystroke 0 of each export burst that fell during the export: one keystroke after a
    /// pause, which is what the §12 hosted typing test times.
    let firstKeystrokeDuringExport: ExportTypingDistribution
    let eventToUpdateWithoutExport: ExportTypingDistribution
    let eventToUpdateDuringExport: ExportTypingDistribution
    let startDelayWithoutExport: ExportTypingDistribution
    let startDelayDuringExport: ExportTypingDistribution
    let cpuWithoutExport: ExportTypingDistribution
    let cpuDuringExport: ExportTypingDistribution
    let exportBusy: ExportBusySummary
    let idleBusy: ExportBusySummary
    let loadRange: [Double]
    /// G0: functional isolation and coverage.
    let coveragePasses: Bool
    /// G1: no regression beyond the margin in any stratum.
    let isolationPasses: Bool
    /// G2: the existing budget holds while export is active.
    let budgetPasses: Bool

    init(
        product: String,
        configuration: String,
        warmExportMilliseconds: Double,
        rounds: [ExportTypingRound],
        windows: [ExportBusyWindow]
    ) {
        self.product = product
        self.configuration = configuration
        self.warmExportMilliseconds = warmExportMilliseconds
        roundCount = rounds.count
        roundsWithDuringSamples = rounds.filter { !$0.duringExport.isEmpty }.count
        fencedRounds = rounds.filter(\.fenceChecked).count
        fenceFailures = rounds.filter { $0.fenceChecked && !$0.fenceHeld }.count
        untouchedViolations = rounds.flatMap(\.exportArm).filter { !$0.exportUntouched }.count
        comparisons = ExportTypingStratum.allCases.map { ExportTypingComparison(stratum: $0, rounds: rounds) }
        let baseline = rounds.flatMap(\.withoutExport)
        let during = rounds.flatMap(\.duringExport)
        firstKeystrokeDuringExport = ExportTypingDistribution(
            during.filter { $0.position == 0 }.map(\.handlerMilliseconds)
        )
        eventToUpdateWithoutExport = ExportTypingDistribution(baseline.map(\.eventToUpdateMilliseconds))
        eventToUpdateDuringExport = ExportTypingDistribution(during.map(\.eventToUpdateMilliseconds))
        startDelayWithoutExport = ExportTypingDistribution(baseline.map(\.startDelayMilliseconds))
        startDelayDuringExport = ExportTypingDistribution(during.map(\.startDelayMilliseconds))
        cpuWithoutExport = ExportTypingDistribution(baseline.map(\.handlerCPUMilliseconds))
        cpuDuringExport = ExportTypingDistribution(during.map(\.handlerCPUMilliseconds))
        exportBusy = ExportBusySummary(windows.filter { $0.kind == "export" })
        idleBusy = ExportBusySummary(windows.filter { $0.kind == "idle" })
        let loads = rounds.flatMap { [$0.loadBefore, $0.loadAfter] }
        loadRange = [loads.min() ?? 0, loads.max() ?? 0]

        let requiredRounds = Int(
            (Double(rounds.count) * ExportTypingStatistics.minimumRoundsWithDuringSamples).rounded(.up)
        )
        coveragePasses = untouchedViolations == 0
            && fenceFailures == 0
            && fencedRounds > 0
            && roundsWithDuringSamples >= requiredRounds
        isolationPasses = comparisons.allSatisfy(\.isolationPasses)
        budgetPasses = firstKeystrokeDuringExport.count > 0
            && firstKeystrokeDuringExport.p95 < ExportTypingStatistics.frameBudget
            && comparisons.allSatisfy { $0.covered && $0.shareWithinMargin }
    }

    var lines: [String] {
        let prefix = "E9 TYPING \(product) \(configuration)"
        var lines = [
            "\(prefix): warm export \(String(format: "%.0f", warmExportMilliseconds)) ms; rounds \(roundCount), "
                + "with keystrokes during export \(roundsWithDuringSamples), fenced \(fencedRounds), "
                + "fence failures \(fenceFailures), untouched violations \(untouchedViolations); "
                + String(format: "load %.2f-%.2f", loadRange[0], loadRange[1]),
        ]
        for comparison in comparisons {
            let interval = comparison.medianDifference
            lines
                .append(
                    "\(prefix) \(comparison.stratum.rawValue) handler without export: \(comparison.withoutExport.line)"
                )
            lines
                .append(
                    "\(prefix) \(comparison.stratum.rawValue) handler during export: \(comparison.duringExport.line)"
                )
            lines.append(
                "\(prefix) \(comparison.stratum.rawValue) median difference "
                    + String(format: "%+.3f [%+.3f, %+.3f] ms", interval.estimate, interval.lower, interval.upper)
                    + " over \(comparison.roundsWithDuringSamples) rounds; covered \(comparison.covered); "
                    + "share within margin \(comparison.shareWithinMargin)"
            )
        }
        lines += [
            "\(prefix) first keystroke during export: \(firstKeystrokeDuringExport.line)",
            "\(prefix) event-to-update without export: \(eventToUpdateWithoutExport.line)",
            "\(prefix) event-to-update during export: \(eventToUpdateDuringExport.line)",
            "\(prefix) start delay without export: \(startDelayWithoutExport.line)",
            "\(prefix) start delay during export: \(startDelayDuringExport.line)",
            "\(prefix) main-thread CPU without export: \(cpuWithoutExport.line)",
            "\(prefix) main-thread CPU during export: \(cpuDuringExport.line)",
            "\(prefix) busy slices, warm export: \(exportBusy.line)",
            "\(prefix) busy slices, idle: \(idleBusy.line)",
            "\(prefix) G0 \(Self.verdict(coveragePasses)); G1 \(Self.verdict(isolationPasses)); "
                + "G2 \(Self.verdict(budgetPasses))",
        ]
        return lines
    }

    private static func verdict(_ passes: Bool) -> String {
        passes ? "PASS" : "FAIL"
    }
}

struct ExportTypingReport: Codable {
    let summary: ExportTypingSummary
    let rounds: [ExportTypingRound]
    let windows: [ExportBusyWindow]
}
