import SwiftUI

struct MALHubCandidateRail: View {
    @EnvironmentObject private var registry: SourceRegistry
    @Environment(\.malDetailStore) private var detailStore
    @Environment(\.malSourceChoiceStore) private var choiceStore
    let candidates: [MALDiscoveryCandidate]
    let detailManga: Manga
    @State private var selected: MALDiscoveryCandidate?

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
                              choiceStore: choiceStore, registry: registry)
        }
    }

    private func stamp(for candidate: MALDiscoveryCandidate) -> String {
        switch candidate.reason {
        case .related(_, let label): return label.uppercased()
        case .recommendation:
            return candidate.resolvedListing == nil ? "NOT ON YOUR SOURCES" : "ON YOUR SOURCES"
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
    @Environment(\.dismiss) private var dismiss

    init(candidate: MALDiscoveryCandidate, detailStore: MALDetailStore,
         choiceStore: MALSourceChoiceStore, registry: SourceRegistry) {
        self.candidate = candidate
        self.detailStore = detailStore
        self.choiceStore = choiceStore
        self.registry = registry
        _model = StateObject(wrappedValue: MALHubPreviewModel(
            candidate: candidate, detailStore: detailStore,
            showAdultContent: AdultContentSetting.current()))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    CachedAsyncImage(url: model.coverURL) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFit()
                        } else {
                            CoverPlaceholder(showsSpinner: model.isLoading)
                        }
                    }
                    .frame(maxWidth: 180, maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: Gutter.cardRadius))
                    .frame(maxWidth: .infinity)
                    Text(model.title)
                        .font(.inkDisplay(28))
                        .foregroundStyle(Ink.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("MAL title · \(candidate.malId)")
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
                        HStack { ProgressView(); Text("Finding a source…") }
                    } else if let resolution {
                        resolutionView(resolution)
                    } else if candidate.resolvedListing != nil || model.canSearchAllSources {
                        Button("Read on…") { resolve() }
                            .buttonStyle(.borderedProminent)
                            .tint(Ink.seal)
                    }
                }
                .padding(Gutter.page)
            }
            .navigationTitle("Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task { await model.load() }
            .onDisappear { resolution = nil }
        }
    }

    @ViewBuilder private func resolutionView(_ value: MALHubResolution) -> some View {
        switch value {
        case .open(let manga):
            NavigationLink("Read on \(manga.title)", destination: MangaDetailView(manga: manga, registry: registry))
                .buttonStyle(.borderedProminent)
        case .chooser(let groups):
            Text("Choose a match").font(.inkDisplay(22))
            ForEach(groups, id: \.sourceId) { group in
                if group.status == .couldNotCheckFailed || group.status == .couldNotCheckTimedOut {
                    Text("Couldn't check · \(group.sourceName)")
                    Button("Try again") { resolve(sourceID: group.sourceId) }
                }
                ForEach(group.choices, id: \.manga.id) { choice in
                    Button {
                        Task {
                            await choiceStore.confirm(malId: candidate.malId,
                                                       sourceId: choice.manga.sourceId,
                                                       manga: choice.manga, title: candidate.title)
                            resolution = .open(choice.manga)
                        }
                    } label: {
                        Text("\(choice.manga.title) · \(choice.kind == .exact ? "Exact match ✓" : "Possible match")")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                }
            }
        case .notFound(let groups):
            Text("Not on your Sources").font(.headline)
            Text("Add a repository in Settings to add more places to read.")
            ForEach(groups.filter { $0.status == .couldNotCheckFailed || $0.status == .couldNotCheckTimedOut }, id: \.sourceId) { group in
                Button("Try again · \(group.sourceName)") { resolve(sourceID: group.sourceId) }
            }
            Button("Done") { dismiss() }.buttonStyle(.bordered)
        }
    }

    private func resolve(sourceID: String? = nil) {
        isResolving = true
        Task {
            defer { isResolving = false }
            let resolver = MALHubResolver(registry: registry, store: choiceStore,
                                          showAdultContent: model.showAdultContent)
            resolution = await resolver.resolve(candidate: candidate, sourceIDs: sourceID.map { [$0] })
        }
    }
}
