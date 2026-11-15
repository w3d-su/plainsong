import Foundation

/// What one probe run does. The defaults are the acceptance shape in
/// `docs/ios/handoffs/11-validation.md`: warm up, then at least 60 keystrokes at a fixed
/// place in the document.
struct IOSPerformanceProbeConfiguration: Codable, Equatable {
    enum Caret: String, Codable, CaseIterable, Identifiable {
        case start, middle, end

        var id: String {
            rawValue
        }

        var title: String {
            switch self {
            case .start: "Start"
            case .middle: "Middle"
            case .end: "End"
            }
        }
    }

    static let minimumAcceptedSamples = 60

    var caret: Caret = .middle
    var warmUpCount = 10
    var sampleCount = IOSPerformanceProbeConfiguration.minimumAcceptedSamples
    /// Time from one keystroke to the next. A keystroke also waits for its highlight, up
    /// to `highlightWaitMilliseconds`, so a slow highlight stretches the interval.
    var keystrokeIntervalMilliseconds = 150
    var highlightWaitMilliseconds = 500
    var previewSampleCount = 20
    var previewWaitMilliseconds = 5000
}

/// One keystroke. Every time is milliseconds after the call that inserted the character.
struct IOSPerformanceTypingSample: Codable, Equatable {
    let index: Int
    /// `insertText` returned: the delegate, storage and line-index work.
    let insertMilliseconds: Double
    /// The main run loop finished the turn that laid out, drew and committed the edit.
    let commitMilliseconds: Double
    /// The first display refresh at or after the commit. The glyph cannot reach the
    /// screen before this; the render server usually shows it one refresh later.
    let refreshMilliseconds: Double
    /// The visible-range highlight for this keystroke was painted. Nil when none was
    /// painted inside the wait.
    let highlightMilliseconds: Double?
}

/// One preview render, measured by PreviewKit from the hand-off to JavaScript to its
/// `renderComplete`. The 150 ms debounce before the hand-off is not part of it.
struct IOSPerformancePreviewSample: Codable, Equatable {
    let index: Int
    let version: Int
    let renderMilliseconds: Double
    /// Keystroke to `renderComplete`, debounce included.
    let editToCompleteMilliseconds: Double
}

struct IOSPerformanceSummary: Codable, Equatable {
    let count: Int
    let median: Double
    let p95: Double
    let maximum: Double

    /// Nearest-rank percentiles, so every reported value is a sample that was measured.
    static func of(_ values: [Double]) -> IOSPerformanceSummary? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return IOSPerformanceSummary(
            count: sorted.count,
            median: nearestRank(0.5, in: sorted),
            p95: nearestRank(0.95, in: sorted),
            maximum: sorted[sorted.count - 1]
        )
    }

    static func nearestRank(_ fraction: Double, in sorted: [Double]) -> Double {
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }
}

struct IOSPerformanceEnvironment: Codable, Equatable {
    var deviceModel: String
    var systemVersion: String
    var appVersion: String
    var appBuild: String
    var buildConfiguration: String
    var maximumFramesPerSecond: Int
    /// The display link's own interval while the run was measured.
    var frameIntervalMilliseconds: Double?
    var thermalStateAtStart: String
    var thermalStateAtEnd: String
    var lowPowerMode: Bool
    var editorWasFirstResponder: Bool
    var previewWasVisible: Bool
    var startedAt: Date
}

struct IOSPerformanceDocument: Codable, Equatable {
    var name: String
    var fileKind: String
    var utf8Bytes: Int
    var utf16Length: Int
    var sha256: String
    var caretUTF16Offset: Int
}

/// Budgets from agent.md §12. A comparison is reported only for a metric that has samples.
struct IOSPerformanceBudgetResult: Codable, Equatable {
    let metric: String
    let budgetMilliseconds: Double
    let p95Milliseconds: Double
    let withinBudget: Bool
}

struct IOSPerformanceReport: Codable, Equatable {
    static let currentSchema = 1

    var schema = IOSPerformanceReport.currentSchema
    var environment: IOSPerformanceEnvironment
    var document: IOSPerformanceDocument
    var configuration: IOSPerformanceProbeConfiguration
    var typing: [IOSPerformanceTypingSample]
    var preview: [IOSPerformancePreviewSample]
    var previewTimeouts: Int
    /// The document's text equals the text the run started from.
    var documentRestored: Bool
    var insert: IOSPerformanceSummary?
    var commit: IOSPerformanceSummary?
    var refresh: IOSPerformanceSummary?
    var highlight: IOSPerformanceSummary?
    var highlightMissing: Int
    var previewRender: IOSPerformanceSummary?
    var budgets: [IOSPerformanceBudgetResult]
    /// Empty when the run can be used as a measurement. Otherwise each entry says why not.
    var inadmissibleReasons: [String]

    var isAdmissible: Bool {
        inadmissibleReasons.isEmpty
    }

    mutating func summarize() {
        insert = .of(typing.map(\.insertMilliseconds))
        commit = .of(typing.map(\.commitMilliseconds))
        refresh = .of(typing.map(\.refreshMilliseconds))
        let highlights = typing.compactMap(\.highlightMilliseconds)
        highlight = .of(highlights)
        highlightMissing = typing.count - highlights.count
        previewRender = .of(preview.map(\.renderMilliseconds))
        budgets = [
            budget("keystroke commit", 16, commit),
            budget("visible highlight", 50, highlight),
            budget("preview render", 100, previewRender),
        ].compactMap { $0 }
        inadmissibleReasons = Self.reasons(for: self)
    }

    private func budget(
        _ metric: String,
        _ limit: Double,
        _ summary: IOSPerformanceSummary?
    ) -> IOSPerformanceBudgetResult? {
        summary.map {
            IOSPerformanceBudgetResult(
                metric: metric,
                budgetMilliseconds: limit,
                p95Milliseconds: $0.p95,
                withinBudget: $0.p95 < limit
            )
        }
    }

    static func reasons(for report: IOSPerformanceReport) -> [String] {
        var reasons: [String] = []
        let environment = report.environment
        if environment.buildConfiguration != "Release" {
            reasons.append("Build configuration is \(environment.buildConfiguration), not Release.")
        }
        if environment.lowPowerMode {
            reasons.append("Low Power Mode was on.")
        }
        for state in [environment.thermalStateAtStart, environment.thermalStateAtEnd]
            where state == "serious" || state == "critical"
        {
            reasons.append("Thermal state was \(state).")
            break
        }
        if report.typing.count < IOSPerformanceProbeConfiguration.minimumAcceptedSamples {
            reasons.append(
                "Only \(report.typing.count) keystroke samples; " +
                    "\(IOSPerformanceProbeConfiguration.minimumAcceptedSamples) are required."
            )
        }
        if !report.documentRestored {
            reasons.append("The document was not restored to its starting text.")
        }
        return reasons
    }

    func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}
