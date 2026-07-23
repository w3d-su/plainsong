import MarkdownCore
import SwiftUI
import WorkspaceKit

/// Lazy grouped results list for workspace search (WS3C PR B/C).
///
/// Presentation is pure (`WorkspaceSearchResultsPresentation`); this view only renders,
/// routes keyboard selection through `WorkspaceSearchSelectionNavigation`, and forwards
/// activation through `activateWorkspaceSearchResult` with the retained context, file result,
/// and match — never URL reconstruction.
struct WorkspaceSearchResultsList: View {
    @EnvironmentObject private var appState: AppState
    let presentation: WorkspaceSearchResultsPresentation
    @Binding var selectedRowID: WorkspaceSearchResultRowID?
    @Binding var isResultsFocused: Bool
    @ObservedObject var keyRouter: WorkspaceSearchKeyRouterController
    var onEscapeToQueryField: () -> Void
    var onActivationResolved: (Bool) -> Void
    var onKeyboardSelectionHandled: (WorkspaceSearchSelectionAction) -> Void

    var body: some View {
        List(selection: $selectedRowID) {
            statusRows
            bannerRows
            resultSections
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier(WorkspaceSearchAccessibility.resultsList)
        .accessibilityLabel("Search results")
        .focusable(presentationHasRows)
        .onKeyPress(.upArrow) {
            guard isResultsFocused else { return .ignored }
            applySelection(.moveUp)
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard isResultsFocused else { return .ignored }
            applySelection(.moveDown)
            return .handled
        }
        .onKeyPress(.return) {
            guard isResultsFocused else { return .ignored }
            activateSelection()
            return .handled
        }
        .onKeyPress(.escape) {
            guard isResultsFocused else { return .ignored }
            onEscapeToQueryField()
            return .handled
        }
        .background(
            WorkspaceSearchResultsKeyRouterReader(
                controller: keyRouter,
                onCommand: handleKeyRouterCommand
            )
        )
    }

    private var presentationHasRows: Bool {
        presentation.sections.contains { !$0.rows.isEmpty }
    }

    private var orderedRowIDs: [WorkspaceSearchResultRowID] {
        WorkspaceSearchSelectionNavigation.orderedRowIDs(in: presentation)
    }

    private var queryGeneration: UInt64 {
        appState.workspaceSearchState.queryGeneration
    }

    // MARK: - Status / banners

    @ViewBuilder
    private var statusRows: some View {
        switch presentation.status {
        case .hidden:
            EmptyView()
        case let .prompt(message):
            statusSection(message)
        case .waiting:
            statusSection("Waiting to search…")
        case let .searching(completed, total):
            let text = total > 0 ? "Searching \(completed)/\(total)…" : "Searching…"
            statusSection(text, showsProgress: true)
        case .noResults:
            statusSection("No Results")
        case let .validationFailure(message):
            statusSection(message, isError: true)
        case let .serviceFailure(message):
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier(WorkspaceSearchAccessibility.status)
                        .accessibilityLabel(
                            WorkspaceSearchAccessibility.statusLabel(presentation.status) ?? message
                        )
                    if presentation.showsRetry {
                        Button("Retry") {
                            retrySearch()
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier(WorkspaceSearchAccessibility.retry)
                        .accessibilityLabel("Retry search")
                    }
                }
            }
        }
    }

    private func statusSection(
        _ message: String,
        showsProgress: Bool = false,
        isError: Bool = false
    ) -> some View {
        Section {
            HStack(spacing: 8) {
                if showsProgress {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                }
                Text(message)
                    .font(.callout)
                    .foregroundStyle(isError ? .red : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(WorkspaceSearchAccessibility.status)
            .accessibilityLabel(
                WorkspaceSearchAccessibility.statusLabel(presentation.status) ?? message
            )
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
            .accessibilityIdentifier(WorkspaceSearchAccessibility.banners)
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
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(WorkspaceSearchAccessibility.banner(banner))
            .accessibilityLabel(WorkspaceSearchAccessibility.bannerLabel(banner))
        case .globalTruncation:
            Label("Results truncated (global match limit)", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .accessibilityIdentifier(WorkspaceSearchAccessibility.banner(banner))
                .accessibilityLabel(WorkspaceSearchAccessibility.bannerLabel(banner))
        case let .perFileTruncation(pathCount):
            Label(
                "Results truncated in \(pathCount) file\(pathCount == 1 ? "" : "s")",
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.orange)
            .accessibilityIdentifier(WorkspaceSearchAccessibility.banner(banner))
            .accessibilityLabel(WorkspaceSearchAccessibility.bannerLabel(banner))
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
                            .accessibilityLabel("Truncated")
                            .help("Matches truncated in this file")
                    }
                    if !section.canActivate {
                        Image(systemName: "nosign")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel("Unavailable")
                            .help("This result can’t be opened")
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(WorkspaceSearchAccessibility.section(section.id))
                .accessibilityLabel(
                    WorkspaceSearchAccessibility.sectionLabel(
                        relativePath: section.relativePath,
                        matchCount: section.matchCount,
                        isTruncated: section.isTruncated,
                        canActivate: section.canActivate
                    )
                )
            }
        }
    }

    private func resultRow(
        _ row: WorkspaceSearchResultRowModel,
        section: WorkspaceSearchResultFileSectionModel
    ) -> some View {
        let isSelected = selectedRowID == row.id
        let label = WorkspaceSearchAccessibility.rowLabel(
            relativePath: section.relativePath,
            lineNumber: row.lineNumber,
            snippet: row.snippet
        )

        return Button {
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
        .accessibilityIdentifier(WorkspaceSearchAccessibility.row(row.id))
        .accessibilityLabel(label)
        .accessibilityValue(WorkspaceSearchAccessibility.rowValue(canActivate: row.canActivate))
        .accessibilityAddTraits(rowTraits(isSelected: isSelected, canActivate: row.canActivate))
    }

    private func rowTraits(
        isSelected: Bool,
        canActivate: Bool
    ) -> AccessibilityTraits {
        switch (canActivate, isSelected) {
        case (true, true):
            [.isButton, .isSelected]
        case (true, false):
            .isButton
        case (false, true):
            .isSelected
        case (false, false):
            []
        }
    }

    // MARK: - Keyboard actions

    private func applySelection(_ action: WorkspaceSearchSelectionAction) {
        selectedRowID = WorkspaceSearchSelectionNavigation.reduce(
            selection: selectedRowID,
            action: action,
            orderedIDs: orderedRowIDs,
            queryGeneration: queryGeneration
        )
        #if DEBUG
            onKeyboardSelectionHandled(action)
            WorkspaceSearchKeyboardSmokeProbe.publish(
                selection: selectedRowID,
                resultsFocused: keyRouter.isFirstResponder
            )
        #endif
    }

    private func handleKeyRouterCommand(_ command: WorkspaceSearchResultsKeyCommand) {
        switch command {
        case .moveUp:
            applySelection(.moveUp)
        case .moveDown:
            applySelection(.moveDown)
        case .activate:
            activateSelection()
        case .escape:
            onEscapeToQueryField()
        }
    }

    private func activateSelection() {
        guard let selectedRowID else { return }
        // Only activate a result still held by the current search state.
        guard let payload = WorkspaceSearchResultsPresenter.activationLookup(
            rowID: selectedRowID,
            searchState: appState.workspaceSearchState
        ) else {
            return
        }
        let didActivate = appState.activateWorkspaceSearchResult(
            context: payload.context,
            fileResult: payload.fileResult,
            match: payload.match
        )
        onActivationResolved(didActivate)
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
        let didActivate = appState.activateWorkspaceSearchResult(
            context: payload.context,
            fileResult: payload.fileResult,
            match: payload.match
        )
        onActivationResolved(didActivate)
    }

    private func retrySearch() {
        if appState.workspaceSearchState.activeQuery != nil {
            appState.restartActiveWorkspaceSearchWithFreshOverlays()
        } else {
            appState.publishWorkspaceSearchQueryFromUI()
        }
    }
}
