import AppKit
import MarkdownCore

/// Main-actor presentation coordinator. Requests are asynchronous, coalesced by source,
/// and guarded by an exact document-text generation before they may touch TextKit.
@MainActor
final class WYSIWYGImagePresentationController {
    private struct Context: Equatable {
        let loaderIdentity: ObjectIdentifier
        let rootPath: String
        let documentDirectoryRelativePath: String
        let maximumPixelSize: Int
        let documentIdentity: EditorDocumentIdentity?
    }

    private struct LoadKey: Hashable {
        let source: String
        let maximumPixelSize: Int
    }

    private struct RegionKey: Hashable {
        let location: Int
        let length: Int
        let source: String
    }

    private struct ParagraphKey: Hashable {
        let location: Int
        let length: Int
    }

    private struct Region {
        let key: RegionKey
        let sourceRange: NSRange
        let paragraphRange: NSRange
        let source: String
        let altText: String
        let loadKey: LoadKey
    }

    private struct ActivePlan {
        let regions: [Region]
        let selection: NSRange
        let availableWidth: CGFloat
    }

    private struct InFlightRequest {
        let id: UUID
        let generation: UInt64
        let task: Task<Void, Never>
    }

    private var configuration: EditorImageThumbnailConfiguration?
    private var context: Context?
    private var documentSource: String?
    private var generation: UInt64 = 0
    private var activePlan: ActivePlan?
    private var outcomes: [LoadKey: EditorImageThumbnailOutcome] = [:]
    private var inFlight: [LoadKey: InFlightRequest] = [:]
    private var appliedMarkers: [RegionKey: WYSIWYGImagePresentationMarker] = [:]
    private weak var textView: MarkdownSTTextView?
    private weak var refreshProxy: EditorImageThumbnailRefreshProxy?
    private let refreshAttachmentID = UUID()

    func updateConfiguration(
        _ configuration: EditorImageThumbnailConfiguration?,
        documentIdentity: EditorDocumentIdentity?,
        isPresentationEnabled: Bool,
        in textView: MarkdownSTTextView
    ) {
        self.textView = textView
        guard isPresentationEnabled, let configuration else {
            if hasPresentationState {
                teardown(in: textView, removeAllMarkers: true)
            }
            return
        }

        let nextContext = Context(
            loaderIdentity: ObjectIdentifier(configuration.loader),
            rootPath: configuration.rootURL.standardizedFileURL.path,
            documentDirectoryRelativePath: configuration.documentDirectoryRelativePath,
            maximumPixelSize: configuration.maximumPixelSize,
            documentIdentity: documentIdentity
        )
        if context != nextContext {
            beginNewContext(nextContext, in: textView)
        }

        self.configuration = configuration
        attachRefreshProxy(configuration.refreshProxy)
    }

    func apply(
        foldPlan: WYSIWYGFoldPlan?,
        source: String,
        selection: NSRange,
        forceReapply: Bool,
        in textView: MarkdownSTTextView
    ) {
        guard configuration != nil,
              context != nil,
              textView.wysiwygZeroWidthContentStorageDelegate != nil,
              let foldPlan
        else {
            clearActivePresentation(in: textView)
            return
        }

        beginSourceIfNeeded(source, in: textView)
        let regions = makeRegions(from: foldPlan.imageRegions, source: source)
        activePlan = ActivePlan(
            regions: regions,
            selection: selection.clamped(toLength: (source as NSString).length),
            availableWidth: availableWidth(in: textView)
        )
        rebuildPresentation(forceReapply: forceReapply, in: textView)
    }

    func documentTextDidChange(in textView: MarkdownSTTextView) {
        guard configuration != nil,
              let source = MarkdownTextView.textStorage(of: textView)?.string,
              documentSource.map({ !ExactUTF16Text.matches($0, source) }) ?? true
        else {
            return
        }

        beginNewSource(source, in: textView)
    }

    func detach(from textView: MarkdownSTTextView) {
        if hasPresentationState {
            teardown(in: textView, removeAllMarkers: true)
        }
        self.textView = nil
    }

    private var hasPresentationState: Bool {
        configuration != nil
            || context != nil
            || documentSource != nil
            || activePlan != nil
            || refreshProxy != nil
            || !outcomes.isEmpty
            || !inFlight.isEmpty
            || !appliedMarkers.isEmpty
    }

    private func beginNewContext(_ context: Context, in textView: MarkdownSTTextView) {
        generation &+= 1
        cancelAllRequests()
        outcomes.removeAll()
        activePlan = nil
        documentSource = nil
        appliedMarkers.removeAll()
        textView.removeAllWYSIWYGImagePresentationMarkers()
        textView.setWYSIWYGImagePresentationGeneration(nil, invalidating: [])
        self.context = context
    }

    private func beginSourceIfNeeded(_ source: String, in textView: MarkdownSTTextView) {
        guard documentSource.map({ !ExactUTF16Text.matches($0, source) }) ?? true else {
            return
        }
        beginNewSource(source, in: textView)
    }

    private func beginNewSource(_ source: String, in textView: MarkdownSTTextView) {
        generation &+= 1
        cancelAllRequests()
        activePlan = nil
        documentSource = source
        let oldRanges = appliedMarkers.values.map(\.sourceRange)
        appliedMarkers.removeAll()
        textView.setWYSIWYGImagePresentationGeneration(nil, invalidating: oldRanges)
    }

    private func clearActivePresentation(in textView: MarkdownSTTextView) {
        guard !appliedMarkers.isEmpty else {
            activePlan = nil
            return
        }
        let oldMarkers = Array(appliedMarkers.values)
        appliedMarkers.removeAll()
        activePlan = nil
        textView.applyWYSIWYGImagePresentationMarkers(
            [],
            replacing: oldMarkers,
            generation: generation,
            forceReapply: false
        )
    }

    private func teardown(in textView: MarkdownSTTextView, removeAllMarkers: Bool) {
        cancelAllRequests()
        attachRefreshProxy(nil)
        configuration = nil
        context = nil
        documentSource = nil
        activePlan = nil
        outcomes.removeAll()
        appliedMarkers.removeAll()
        if removeAllMarkers {
            textView.removeAllWYSIWYGImagePresentationMarkers()
        }
        textView.setWYSIWYGImagePresentationGeneration(nil, invalidating: [])
    }
}

@MainActor
private extension WYSIWYGImagePresentationController {
    private func makeRegions(
        from imageRegions: [MarkdownInlineImageRegion],
        source: String
    ) -> [Region] {
        let storage = source as NSString
        var seen: Set<RegionKey> = []
        return imageRegions.compactMap { region in
            guard region.sourceRange.location != NSNotFound,
                  region.sourceRange.length > 0,
                  NSMaxRange(region.sourceRange) <= storage.length,
                  NSMaxRange(region.altTextRange) <= storage.length,
                  NSMaxRange(region.sourcePathRange) <= storage.length
            else {
                return nil
            }

            let imageSource = storage.substring(with: region.sourcePathRange)
            let key = RegionKey(
                location: region.sourceRange.location,
                length: region.sourceRange.length,
                source: imageSource
            )
            guard seen.insert(key).inserted else {
                return nil
            }

            return Region(
                key: key,
                sourceRange: region.sourceRange,
                paragraphRange: storage.paragraphRange(for: region.sourceRange),
                source: imageSource,
                altText: storage.substring(with: region.altTextRange),
                loadKey: LoadKey(
                    source: imageSource,
                    maximumPixelSize: configuration?.maximumPixelSize
                        ?? EditorImageThumbnailConfiguration.defaultMaximumPixelSize
                )
            )
        }
    }

    func rebuildPresentation(forceReapply: Bool, in textView: MarkdownSTTextView) {
        guard let activePlan else {
            clearActivePresentation(in: textView)
            return
        }

        let paragraphImageCounts = Dictionary(
            grouping: activePlan.regions,
            by: { ParagraphKey(location: $0.paragraphRange.location, length: $0.paragraphRange.length) }
        ).mapValues(\.count)

        var nextMarkers: [RegionKey: WYSIWYGImagePresentationMarker] = [:]
        var keysNeedingLoad: Set<LoadKey> = []
        for region in activePlan.regions where !activePlan.selection.touchesImageRange(region.sourceRange) {
            let outcome = outcomes[region.loadKey]
            if case .stayRaw = outcome {
                continue
            }
            if outcome == nil {
                keysNeedingLoad.insert(region.loadKey)
            }

            let paragraphKey = ParagraphKey(
                location: region.paragraphRange.location,
                length: region.paragraphRange.length
            )
            let canvasSize = WYSIWYGImagePresentationMetrics.canvasSize(
                availableWidth: activePlan.availableWidth,
                imageCountInParagraph: paragraphImageCounts[paragraphKey] ?? 1
            )
            let proposed = WYSIWYGImagePresentationMarker(
                generation: generation,
                sourceRange: region.sourceRange,
                source: region.source,
                altText: region.altText,
                canvasSize: canvasSize,
                outcome: outcome
            )
            if let existing = appliedMarkers[region.key], existing.signature == proposed.signature {
                nextMarkers[region.key] = existing
            } else {
                nextMarkers[region.key] = proposed
            }
        }

        let previousMarkers = Array(appliedMarkers.values)
        appliedMarkers = nextMarkers
        textView.applyWYSIWYGImagePresentationMarkers(
            Array(nextMarkers.values),
            replacing: previousMarkers,
            generation: generation,
            forceReapply: forceReapply
        )

        for key in keysNeedingLoad {
            scheduleLoad(for: key, in: textView)
        }
    }

    private func scheduleLoad(for key: LoadKey, in textView: MarkdownSTTextView) {
        guard inFlight[key] == nil,
              let configuration
        else {
            return
        }

        let id = UUID()
        let requestGeneration = generation
        let loader = configuration.loader
        let rootURL = configuration.rootURL
        let directory = configuration.documentDirectoryRelativePath
        let task = Task { [weak self, weak textView] in
            let outcome = await loader.loadThumbnail(
                rootURL: rootURL,
                documentDirectoryRelativePath: directory,
                source: key.source,
                maxPixelSize: key.maximumPixelSize
            )
            guard let self, let textView else {
                return
            }
            completeLoad(
                outcome,
                for: key,
                id: id,
                requestGeneration: requestGeneration,
                in: textView
            )
        }
        inFlight[key] = InFlightRequest(id: id, generation: requestGeneration, task: task)
    }

    private func completeLoad(
        _ outcome: EditorImageThumbnailOutcome,
        for key: LoadKey,
        id: UUID,
        requestGeneration: UInt64,
        in textView: MarkdownSTTextView
    ) {
        guard let request = inFlight[key],
              request.id == id,
              request.generation == requestGeneration
        else {
            return
        }
        inFlight[key] = nil
        guard generation == requestGeneration,
              self.textView === textView,
              configuration != nil
        else {
            return
        }

        outcomes[key] = outcome
        rebuildPresentation(forceReapply: false, in: textView)
    }

    func cancelAllRequests() {
        for request in inFlight.values {
            request.task.cancel()
        }
        inFlight.removeAll()
    }

    func attachRefreshProxy(_ proxy: EditorImageThumbnailRefreshProxy?) {
        guard refreshProxy !== proxy else {
            return
        }
        refreshProxy?.detach(id: refreshAttachmentID)
        refreshProxy = proxy
        proxy?.attach(id: refreshAttachmentID) { [weak self] paths in
            self?.invalidate(paths: paths)
        }
    }

    func invalidate(paths: Set<String>) {
        guard let textView else {
            return
        }

        let knownKeys = Set(outcomes.keys).union(inFlight.keys)
        var affectedKeys = Set(knownKeys.compactMap { key -> LoadKey? in
            if let outcome = outcomes[key],
               case let .ready(thumbnail) = outcome,
               paths.contains(thumbnail.resolvedWorkspaceRelativePath)
            {
                return key
            }
            guard let expectedPath = expectedWorkspaceRelativePath(for: key.source) else {
                return nil
            }
            return paths.contains(expectedPath) ? key : nil
        })
        if let activePlan {
            affectedKeys.formUnion(activePlan.regions.compactMap { region in
                guard let expectedPath = expectedWorkspaceRelativePath(for: region.source),
                      paths.contains(expectedPath)
                else {
                    return nil
                }
                return region.loadKey
            })
        }
        guard !affectedKeys.isEmpty else {
            return
        }

        for key in affectedKeys {
            outcomes[key] = nil
            inFlight[key]?.task.cancel()
            inFlight[key] = nil
        }
        if activePlan != nil {
            rebuildPresentation(forceReapply: false, in: textView)
        }
    }

    func expectedWorkspaceRelativePath(for source: String) -> String? {
        guard let configuration,
              !source.hasPrefix("/")
        else {
            return nil
        }
        let combined = (configuration.documentDirectoryRelativePath as NSString)
            .appendingPathComponent(source)
        return EditorImageThumbnailRefreshProxy.normalizedWorkspaceRelativePath(combined)
    }

    func availableWidth(in textView: MarkdownSTTextView) -> CGFloat {
        let containerWidth = textView.textContainer.size.width
            - textView.textContainer.lineFragmentPadding * 2
        if containerWidth.isFinite, containerWidth > 1 {
            return containerWidth
        }
        return max(textView.bounds.width - (textView.gutterView?.frame.width ?? 0), 1)
    }
}

private extension NSRange {
    func touchesImageRange(_ imageRange: NSRange) -> Bool {
        if length == 0 {
            return location >= imageRange.location && location <= NSMaxRange(imageRange)
        }
        return NSIntersectionRange(self, imageRange).length > 0
    }
}
