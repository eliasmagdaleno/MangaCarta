import SwiftUI

struct AddSourceSheet: View {
    let manga: Manga
    let registry: SourceRegistry
    let works: WorkStore
    let coordinator: WorkSourcesCoordinator
    let listingCountCache: ListingCountCache
    let onAdded: () -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: AddSourceModel
    @State private var decision: AddSourceDecision?
    @State private var pendingRow: AddSourceRow?
    @State private var showingConfirmation = false
    @State private var failureMessage: String?

    init(manga: Manga, registry: SourceRegistry, works: WorkStore,
         coordinator: WorkSourcesCoordinator, listingCountCache: ListingCountCache,
         onAdded: @escaping () -> Void) {
        self.manga = manga
        self.registry = registry
        self.works = works
        self.coordinator = coordinator
        self.listingCountCache = listingCountCache
        self.onAdded = onAdded
        let search = SourceTitleSearch(registry: registry,
                                       showAdultContent: AdultContentSetting.current())
        let counts = MALHubChapterCountLoader(registry: registry, cache: listingCountCache)
        _model = StateObject(wrappedValue: AddSourceModel(listing: manga, registry: registry,
                                                          works: works, coordinator: coordinator,
                                                          search: search, counts: counts))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Gutter.section) {
                    TextField("Search your Sources", text: $model.query)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.search)
                        .onSubmit { Task { await model.submit() } }
                        .accessibilityIdentifier("addSourceSearchField")

                    content
                }
                .padding(Gutter.page)
            }
            .alert("Couldn’t add Source", isPresented: Binding(
                get: { failureMessage != nil }, set: { if !$0 { failureMessage = nil } })) {
                Button("Cancel", role: .cancel) { failureMessage = nil }
            } message: {
                Text(failureMessage ?? "Could not add this Source")
            }
            .navigationTitle("Add a Source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task { await model.start() }
        .onChange(of: model.didAdd) { _, added in
            guard added else { return }
            onAdded()
            dismiss()
        }
        .challengeSheets(nested: true)
        .alert("Add this Source?", isPresented: $showingConfirmation) {
            if let value = decision {
                confirmationButtons(for: value)
            }
        } message: {
            Text(message(for: decision))
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle, .searching:
            if model.phase == .searching {
                ProgressView("Searching your Sources")
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        case .noOtherSources:
            VStack(alignment: .leading, spacing: 12) {
                Text("No other Sources to search").font(.headline)
                Text("Add a repository in Settings to add more places to read.")
                    .foregroundStyle(Ink.secondary)
            }
        case .loaded:
            if let message = model.emptyMessage {
                Text(message).font(.headline)
            }
            ForEach(model.groups, id: \.sourceId) { group in
                sourceGroup(group)
            }
        }
    }

    @ViewBuilder private func sourceGroup(_ group: AddSourceGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(group.sourceName).font(.headline).foregroundStyle(Ink.primary)
            if group.status == .couldNotCheckFailed || group.status == .couldNotCheckTimedOut {
                Text("Couldn’t check").foregroundStyle(Ink.secondary)
                Button("Try again, \(group.sourceName)") {
                    Task { await model.retry(sourceId: group.sourceId) }
                }
                .accessibilityIdentifier("addSourceRetry.\(group.sourceId)")
            } else if group.status == .noResults {
                Text("No results").foregroundStyle(Ink.secondary)
            }
            ForEach(group.rows) { row in
                rowView(row)
            }
        }
    }

    private func rowView(_ row: AddSourceRow) -> some View {
        Button {
            Task {
                let result = await model.pick(row)
                await MainActor.run { handle(result, row: row) }
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                CachedAsyncImage(url: row.manga.coverURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        CoverPlaceholder(showsSpinner: row.manga.coverURL != nil)
                    }
                }
                .frame(width: 76, height: 108)
                .clipShape(RoundedRectangle(cornerRadius: Gutter.cardRadius))
                Text(row.manga.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                if let alternate = row.matchedAlternateTitle {
                    Text("Also known as \(alternate)").foregroundStyle(Ink.secondary)
                }
                if let grade = row.grade.label {
                    Text(grade).foregroundStyle(Ink.seal)
                }
                if row.countRequested {
                    Text(row.chapterCount.map { "\(String($0)) chapters" } ?? "Chapter count unknown")
                        .foregroundStyle(Ink.secondary)
                }
                if row.wasRemovedEarlier {
                    Text("Removed earlier").foregroundStyle(Ink.secondary)
                }
                if row.isAlreadyLinked {
                    Text("Already a Source for this title").foregroundStyle(Ink.secondary)
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .disabled(row.isAlreadyLinked)
        .accessibilityLabel(row.accessibilityLabel + (row.wasRemovedEarlier ? ", Removed earlier" : "") +
                            (row.isAlreadyLinked ? ", Already a Source for this title" : ""))
        .accessibilityIdentifier("addSourceRow.\(row.manga.sourceId).\(row.manga.id)")
    }

    private func handle(_ result: AddSourceDecision, row: AddSourceRow? = nil) {
        switch result {
        case .added, .unavailable: break
        case .confirmDifferentEntry, .confirmCombine, .confirmCombineOrMove:
            pendingRow = row
            decision = result
            showingConfirmation = true
        case .failed(let message): failureMessage = message
        }
    }

    @ViewBuilder private func confirmationButtons(for value: AddSourceDecision) -> some View {
        switch value {
        case .confirmDifferentEntry:
            Button("Add anyway") { confirm(value, action: model.addAnyway) }
            Button("Cancel", role: .cancel) {}
        case .confirmCombine:
            Button("Add") { confirm(value, action: model.combine) }
            Button("Cancel", role: .cancel) {}
        case .confirmCombineOrMove:
            Button("Combine the titles") { confirm(value, action: model.combine) }
            Button("Move just this copy") { confirm(value, action: model.moveJustThisCopy) }
            Button("Cancel", role: .cancel) {}
        default: Button("Cancel", role: .cancel) {}
        }
    }

    private func message(for value: AddSourceDecision?) -> String {
        guard let value else { return "" }
        switch value {
        case .confirmDifferentEntry(let title):
            return "MyAnimeList lists this as a different title, \(title). Add it anyway?"
        case .confirmCombine(let title), .confirmCombineOrMove(let title):
            return "This is also \(title) in your Library. Adding it makes them one title."
        default: return ""
        }
    }

    private func confirm(_ value: AddSourceDecision,
                         action: @escaping (AddSourceRow) async -> AddSourceDecision) {
        guard let row = pendingRow else { return }
        decision = nil
        showingConfirmation = false
        pendingRow = nil
        Task {
            let result = await action(row)
            await MainActor.run { handle(result, row: row) }
        }
    }
}
