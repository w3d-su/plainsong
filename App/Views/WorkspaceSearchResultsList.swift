import MarkdownCore
import SwiftUI
import WorkspaceKit

/// Lazy grouped results list for workspace search (WS3C PR B).
///
/// Presentation is pure (`WorkspaceSearchResultsPresentation`); this view only renders and
/// forwards activation through `activateWorkspaceSearchResult` with the retained context,
/// file result, and match — never URL reconstruction.
struct WorkspaceSearchResultsList: View {
    @EnvironmentObject private var appState: AppState
    let presentation: WorkspaceSearchResultsPresentation
    @Binding var selectedRowID: WorkspaceSearchResultRowID?

    var body: some View {
        List(selection: $selectedRowID) {
            statusRows
            bannerRows
            resultSections
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var statusRows: some View {
        switch presentation.status {
        case .hidden:
            EmptyView()
        case let .prompt(message):
            Section {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .waiting:
            Section {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Waiting to search…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        case let .searching(completed, total):
            Section {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    if total > 0 {
                        Text("Searching \(completed)/\(total)…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Searching…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        case .noResults:
            Section {
                Text("No Results")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case let .validationFailure(message):
            Section {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        case let .serviceFailure(message):
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.red)
                    if presentation.showsRetry {
                        Button("Retry") {
                            retrySearch()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var bannerRows: some View {
        if !presentation.banners.isEmpty {
            Section {
                ForEach(presentation.banners) { banner in
                    bannerView(banner)
                }
            }
        }
    }

    @ViewBuilder
    private func bannerView(_ banner: WorkspaceSearchBanner) -> some View {
        switch banner {
        case let .skipped(count, detailLines, omitted):
            VStack(alignment: .leading, spacing: 4) {
                Text(skippedTitle(count: count, omitted: omitted))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(Array(detailLines.prefix(8).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if detailLines.count > 8 {
                    Text("…and \(detailLines.count - 8) more detail\(detailLines.count - 8 == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 2)
        case .globalTruncation:
            Label("Results truncated (global match limit)", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        case let .perFileTruncation(pathCount):
            Label(
                "Results truncated in \(pathCount) file\(pathCount == 1 ? "" : "s")",
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.orange)
        }
    }

    private var resultSections: some View {
        ForEach(presentation.sections) { section in
            Section {
                ForEach(section.rows) { row in
                    resultRow(row, section: section)
                }
            } header: {
                HStack(spacing: 6) {
                    Text(section.relativePath)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Text("\(section.matchCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if section.isTruncated {
                        Image(systemName: "ellipsis.circle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .help("Matches truncated in this file")
                    }
                    if !section.canActivate {
                        Image(systemName: "nosign")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .help("This result can’t be opened")
                    }
                }
            }
        }
    }

    private func resultRow(
        _ row: WorkspaceSearchResultRowModel,
        section: WorkspaceSearchResultFileSectionModel
    ) -> some View {
        Button {
            activate(row)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(row.lineNumber)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 28, alignment: .trailing)
                // Lazy: attributed snippet is built only for visible rows.
                Text(
                    WorkspaceSearchSnippetHighlight.attributedSnippet(
                        row.snippet,
                        matchRange: row.previewMatchRange
                    )
                )
                .font(.callout)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
            .opacity(row.canActivate ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .disabled(!row.canActivate)
        .tag(row.id)
        .help(
            row.canActivate
                ? "Open \(section.relativePath) at line \(row.lineNumber)"
                : "This result can’t be opened"
        )
        .accessibilityLabel(
            "\(section.relativePath), line \(row.lineNumber), \(row.snippet)"
        )
    }

    private func skippedTitle(count: Int, omitted: Int) -> String {
        var text = "Skipped \(count) file\(count == 1 ? "" : "s")"
        if omitted > 0 {
            text += " (\(omitted) detail\(omitted == 1 ? "" : "s") omitted)"
        }
        return text
    }

    private func activate(_ row: WorkspaceSearchResultRowModel) {
        guard row.canActivate else { return }
        guard let payload = WorkspaceSearchResultsPresenter.activationLookup(
            rowID: row.id,
            searchState: appState.workspaceSearchState
        ) else {
            return
        }
        selectedRowID = row.id
        appState.activateWorkspaceSearchResult(
            context: payload.context,
            fileResult: payload.fileResult,
            match: payload.match
        )
    }

    private func retrySearch() {
        if appState.workspaceSearchState.activeQuery != nil {
            appState.restartActiveWorkspaceSearchWithFreshOverlays()
        } else {
            appState.publishWorkspaceSearchQueryFromUI()
        }
    }
}
