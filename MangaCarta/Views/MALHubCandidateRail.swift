import SwiftUI

struct MALHubCandidateRail: View {
    @EnvironmentObject private var registry: SourceRegistry
    @Environment(\.malDetailStore) private var detailStore
    @Environment(\.malDetailFetch) private var detailFetch
    @Environment(\.malSourceChoiceStore) private var choiceStore
    let candidates: [MALDiscoveryCandidate]
    let detailManga: Manga
    @State private var selected: MALDiscoveryCandidate?
    @State private var opened: Manga?
    @State private var openedID: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: Gutter.rail) {
                ForEach(candidates) { candidate in
                    Button {
                        selected = candidate
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            MangaCoverCard(title: candidate.title, coverURL: candidate.coverURL,
                                           stamp: stamp(for: candidate))
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("malCandidateCard")
                    .accessibilityLabel(MALHubCardAccessibility.label(for: candidate))
                }
            }
            .padding(.horizontal, Gutter.page)
        }
        .sheet(item: $selected) { candidate in
            MALHubPreviewView(candidate: candidate, detailStore: detailStore,
                              choiceStore: choiceStore, registry: registry,
                              fetchDetail: detailFetch) { manga in
                selected = nil
                opened = manga
                openedID = manga.id
            }
        }
        .navigationDestination(item: $openedID) { _ in
            if let opened {
                MangaDetailView(manga: opened, registry: registry)
            }
        }
    }

    private func stamp(for candidate: MALDiscoveryCandidate) -> String {
        let availability = candidate.resolvedListing == nil
            ? "NOT ON YOUR SOURCES"
            : "ON YOUR SOURCES"
        switch candidate.reason {
        case .related(_, let label): return "\(label.uppercased()) · \(availability)"
        case .recommendation: return availability
        }
    }
}

struct MALHubPreviewView: View {
    let candidate: MALDiscoveryCandidate
    let detailStore: MALDetailStore
    let choiceStore: MALSourceChoiceStore
    let registry: SourceRegistry
    @StateObject private var model: MALHubPreviewModel
    @State private var resolution: MALHubResolution?
    @State private var isResolving = false
    @State private var resolutionTask: Task<Void, Never>?
    @State private var rememberedChoice: MALSourceChoice?
    @State private var didOpenResolution = false
    @State private var chapterCounts: [ListingKey: Int] = [:]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.listingCountCache) private var listingCountCache
    private let resolver: MALHubResolver
    private let open: (Manga) -> Void

    init(candidate: MALDiscoveryCandidate, detailStore: MALDetailStore,
         choiceStore: MALSourceChoiceStore, registry: SourceRegistry,
         fetchDetail: @escaping @Sendable (Int) async throws -> MyAnimeListMangaDetail,
         open: @escaping (Manga) -> Void) {
        self.candidate = candidate
        self.detailStore = detailStore
        self.choiceStore = choiceStore
        self.registry = registry
        self.open = open
        let showAdultContent = AdultContentSetting.current()
        _model = StateObject(wrappedValue: MALHubPreviewModel(
            candidate: candidate, detailStore: detailStore,
            showAdultContent: showAdultContent, fetch: fetchDetail))
        resolver = MALHubResolver(registry: registry, store: choiceStore,
                                  showAdultContent: showAdultContent)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    CachedAsyncImage(url: model.coverURL) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFill()
                        } else {
                            CoverPlaceholder(showsSpinner: model.isLoading && model.coverURL != nil)
                        }
                    }
                    // A fixed cover shape: the placeholder has no size of its own and
                    // collapsed to a strip when MAL had no picture.
                    .frame(width: 180, height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: Gutter.cardRadius))
                    .frame(maxWidth: .infinity)
                    Text(model.title)
                        .font(.inkDisplay(28))
                        .foregroundStyle(Ink.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    // `String(_:)`: a bare Int interpolation is localized, and "1,600" is not an id.
                    Text("MAL title · \(String(candidate.malId))")
                        .font(.inkMono(11, weight: .semibold))
                        .foregroundStyle(Ink.secondary)
                    if model.detailsUnavailable {
                        Text("Details unavailable")
                            .foregroundStyle(Ink.secondary)
                    } else {
                        Text(model.synopsis?.isEmpty == false ? model.synopsis! : "No synopsis available")
                            .font(.body)
                            .foregroundStyle(Ink.secondary)
                        if !model.genres.isEmpty {
                            Text(model.genres.joined(separator: " · "))
                                .foregroundStyle(Ink.secondary)
                        }
                        if !model.alternativeTitles.isEmpty {
                            Text("Also known as: \(model.alternativeTitles.joined(separator: ", "))")
                                .foregroundStyle(Ink.secondary)
                        }
                    }
                    if isResolving {
                        HStack {
                            ProgressView()
                            Text("Finding a source…")
                            Button("Cancel") { cancelResolution() }
                                .frame(minHeight: 44)
                        }
                    } else if let resolution {
                        resolutionView(resolution)
                    } else if candidate.resolvedListing != nil || model.canSearchAllSources {
                        Button("Read on…") { resolve() }
                            .buttonStyle(.borderedProminent)
                            .tint(Ink.seal)
                            .frame(minHeight: 44)
                    }
                }
                .padding(Gutter.page)
            }
            .navigationTitle("Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if rememberedChoice != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu("Source") {
                            Button("Choose another Source") {
                                Task {
                                    await choiceStore.remove(malId: candidate.malId)
                                    rememberedChoice = nil
                                    resolution = nil
                                    resolve()
                                }
                            }
                        }
                    }
                }
            }
            .task {
                await model.load()
            }
            .task { rememberedChoice = await choiceStore.choice(for: candidate.malId) }
            .task(id: resolution) {
                guard case .chooser(let groups) = resolution else { return }
                let loader = MALHubChapterCountLoader(registry: registry, cache: listingCountCache)
                chapterCounts = await loader.load(groups)
            }
            .onDisappear {
                cancelResolution()
                resolution = nil
            }
        }
        // `Read on…` searches Sources from inside this sheet, and the root can't present a
        // challenge over it (`ChallengeSheets`).
        .challengeSheets(nested: true)
    }

    @ViewBuilder private func resolutionView(_ value: MALHubResolution) -> some View {
        switch value {
        case .open(let manga):
            Text("Ready to read on \(registry.source(id: manga.sourceId)?.name ?? manga.sourceId)")
                .foregroundStyle(Ink.secondary)
                .task {
                    guard !didOpenResolution else { return }
                    didOpenResolution = true
                    dismiss()
                    open(manga)
                }
        case .chooser(let groups):
            ForEach(groups, id: \.sourceId) { group in
                if Self.couldNotCheck(group) { couldNotCheckRow(group) }
                if !group.choices.isEmpty {
                    Text(group.sourceName).font(.headline)
                    if group.ambiguous { Text("Choose a match").foregroundStyle(Ink.secondary) }
                }
                ForEach(group.choices, id: \.manga.id) { choice in
                    Button {
                        Task {
                            await choiceStore.confirm(malId: candidate.malId,
                                                       sourceId: choice.manga.sourceId,
                                                       manga: choice.manga, title: candidate.title)
                            dismiss()
                            open(choice.manga)
                        }
                    } label: {
                        chooserRow(choice, count: chapterCounts[ListingKey(choice.manga)])
                    }
                    .buttonStyle(.bordered)
                    // A capsule balloons into an oval once rows wrap at large Dynamic Type.
                    .buttonBorderShape(.roundedRectangle(radius: Gutter.cardRadius))
                    .multilineTextAlignment(.leading)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(choiceAccessibilityLabel(choice, count: chapterCounts[ListingKey(choice.manga)]))
                }
            }
        case .notFound(let groups):
            // A Source that couldn't be checked is not evidence of absence (design §5), so
            // the headline only claims what the Sources that answered said.
            let failed = groups.filter(Self.couldNotCheck)
            if failed.isEmpty {
                Text("Not on your Sources").font(.headline)
            } else if failed.count < groups.count {
                Text("Not on the Sources that answered").font(.headline)
            }
            ForEach(failed, id: \.sourceId) { couldNotCheckRow($0) }
            Text("Add a repository in Settings to add more places to read.")
        }
    }

    private static func couldNotCheck(_ group: MALHubSourceGroup) -> Bool {
        group.status == .couldNotCheckFailed || group.status == .couldNotCheckTimedOut
    }

    @ViewBuilder private func couldNotCheckRow(_ group: MALHubSourceGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(group.sourceName).font(.headline)
            Text("Couldn't check").foregroundStyle(Ink.secondary)
        }
        Button("Try again") { resolve(sourceID: group.sourceId) }
            .frame(minHeight: 44)
            .accessibilityLabel("Try again, \(group.sourceName)")
    }

    /// `sourceID` is a "Try again" on that one Source, merged into the groups on screen.
    private func resolve(sourceID: String? = nil) {
        let shown: [MALHubSourceGroup]
        switch resolution {
        case .chooser(let groups), .notFound(let groups): shown = groups
        default: shown = []
        }
        cancelResolution()
        isResolving = true
        resolutionTask = Task {
            let result: MALHubResolution
            if let sourceID {
                result = await resolver.retry(sourceID: sourceID, candidate: candidate,
                                              detail: model.detail, keeping: shown)
            } else {
                result = await resolver.resolve(candidate: candidate, detail: model.detail)
            }
            // A cancelled task must not touch state: a newer resolve may own it by now.
            guard !Task.isCancelled else { return }
            isResolving = false
            resolution = result
        }
    }

    private func cancelResolution() {
        resolutionTask?.cancel()
        resolutionTask = nil
        isResolving = false
    }

    private func chooserRow(_ choice: MALHubChoice, count: Int?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            CachedAsyncImage(url: choice.manga.coverURL) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    CoverPlaceholder()
                }
            }
            .frame(width: 48, height: 68)
            .clipShape(RoundedRectangle(cornerRadius: Gutter.cardRadius))
            VStack(alignment: .leading, spacing: 4) {
                Text(choice.manga.title)
                    .fixedSize(horizontal: false, vertical: true)
                let alternateTitles = Self.alternateTitles(of: choice)
                if !alternateTitles.isEmpty {
                    Text(alternateTitles.joined(separator: ", "))
                        .font(.footnote)
                        .foregroundStyle(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Label(choice.kind == .exact ? "Exact match" : "Possible match",
                      systemImage: choice.kind == .exact ? "checkmark.seal" : "questionmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Ink.secondary)
                Text(Self.chapterCountText(count))
                    .font(.footnote)
                    .foregroundStyle(Ink.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Design "Accessibility": Source, title, confidence, alternate titles, chapter count.
    private func choiceAccessibilityLabel(_ choice: MALHubChoice, count: Int?) -> String {
        let confidence = choice.kind == .exact ? "exact match" : "possible match"
        var parts = [choice.manga.title, choice.sourceName, confidence]
        let alternates = Self.alternateTitles(of: choice)
        if !alternates.isEmpty { parts.append("also known as \(alternates.joined(separator: ", "))") }
        parts.append(Self.chapterCountText(count))
        return parts.joined(separator: ", ")
    }

    private static func alternateTitles(of choice: MALHubChoice) -> [String] {
        (choice.manga.altTitles ?? []).filter { $0 != choice.manga.title }
    }

    /// Unknown is never shown as zero (ADR-0004's `nil` rule).
    static func chapterCountText(_ count: Int?) -> String {
        switch count {
        case nil: return "Chapter count unknown"
        case 1: return "1 chapter"
        case let count?: return "\(count) chapters"
        }
    }
}
