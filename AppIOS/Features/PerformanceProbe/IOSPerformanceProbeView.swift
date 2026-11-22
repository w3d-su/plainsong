import SwiftUI

/// A compact card over the document. It stays small so the editor it measures remains on
/// screen, laid out and first responder.
struct IOSPerformanceProbePanel: View {
    @ObservedObject var probe: IOSPerformanceProbe

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Performance Probe").font(.headline)
                Spacer()
                Button("Close") {
                    probe.cancel()
                    probe.isPanelPresented = false
                    probe.reset()
                }
                .disabled(probe.isRunning)
            }
            content
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 12)
        .accessibilityIdentifier("plainsong.ios.performanceProbe")
    }

    @ViewBuilder private var content: some View {
        switch probe.phase {
        case .idle:
            Text("Types into the open document, measures each keystroke, then deletes what it typed. " +
                "Use a disposable copy of a test file.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Picker("Caret", selection: $probe.configuration.caret) {
                ForEach(IOSPerformanceProbeConfiguration.Caret.allCases) { caret in
                    Text(caret.title).tag(caret)
                }
            }
            .pickerStyle(.segmented)
            Button("Start") { probe.start() }
                .buttonStyle(.borderedProminent)
        case let .running(progress):
            HStack {
                ProgressView()
                Text(progress).font(.footnote).monospacedDigit()
                Spacer()
                Button("Cancel") { probe.cancel() }
            }
        case let .failed(message):
            Text(message).font(.footnote)
            Button("Try Again") { probe.reset() }
        case let .finished(report):
            IOSPerformanceReportSummary(report: report)
            HStack {
                if let file = IOSPerformanceReportFile(report: report) {
                    ShareLink(item: file.url) {
                        Label("Share Report", systemImage: "square.and.arrow.up")
                    }
                }
                Spacer()
                Button("Run Again") { probe.reset() }
            }
        }
    }
}

private struct IOSPerformanceReportSummary: View {
    let report: IOSPerformanceReport

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row("Insert", report.insert)
            row("Commit", report.commit)
            row("Refresh", report.refresh)
            row("Highlight", report.highlight)
            row("Preview render", report.previewRender)
            if report.highlightMissing > 0 {
                Text("\(report.highlightMissing) keystrokes had no highlight inside the wait.")
            }
            if report.previewTimeouts > 0 {
                Text("\(report.previewTimeouts) preview renders timed out.")
            }
            ForEach(report.inadmissibleReasons, id: \.self) { reason in
                Label(reason, systemImage: "exclamationmark.triangle")
            }
        }
        .font(.footnote)
        .monospacedDigit()
    }

    private func row(_ title: String, _ summary: IOSPerformanceSummary?) -> some View {
        HStack {
            Text(title)
            Spacer()
            if let summary {
                Text(String(
                    format: "p50 %.1f  p95 %.1f  max %.1f ms  (n=%d)",
                    summary.median, summary.p95, summary.maximum, summary.count
                ))
            } else {
                Text("no samples").foregroundStyle(.secondary)
            }
        }
    }
}

/// The report as a JSON file in the temporary directory, for the share sheet.
struct IOSPerformanceReportFile {
    let url: URL

    init?(report: IOSPerformanceReport, directory: URL = FileManager.default.temporaryDirectory) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "plainsong-ios-perf-\(formatter.string(from: report.environment.startedAt)).json"
        let url = directory.appendingPathComponent(name)
        guard let data = try? report.encodedJSON(), (try? data.write(to: url, options: .atomic)) != nil else {
            return nil
        }
        self.url = url
    }
}

private struct IOSPerformanceProbeKey: EnvironmentKey {
    static let defaultValue: IOSPerformanceProbe? = nil
}

extension EnvironmentValues {
    var plainsongPerformanceProbe: IOSPerformanceProbe? {
        get { self[IOSPerformanceProbeKey.self] }
        set { self[IOSPerformanceProbeKey.self] = newValue }
    }
}
