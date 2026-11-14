import SwiftUI

struct LibraryMigrateSheet: View {
    let registry: SourceRegistry
    let works: WorkStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: LibraryMigrationModel
    @State private var fromID: String?
    @State private var toID: String?
    @State private var showingChoices: ListingKey?
    @State private var pendingDifferent: (ListingKey, AddSourceRow)?
    @State private var showingDifferent = false
    @State private var showingApply = false
    @State private var removingOld = false
    @State private var summary: LibraryMigrationSummary?
    @State private var runID = UUID()
    @State private var isApplying = false

    init(library: LibraryStore, works: WorkStore, coordinator: WorkSourcesCoordinator,
         registry: SourceRegistry, listingCountCache: ListingCountCache,
         composition: AppComposition.ExtensionComposition?) {
        self.registry = registry
        self.works = works
        let counts = MALHubChapterCountLoader(registry: registry, cache: listingCountCache)
        let model = LibraryMigrationModel(
            library: library, works: works, coordinator: coordinator, registry: registry,
            search: SourceTitleSearch(registry: registry, showAdultContent: AdultContentSetting.current()),
            counts: counts,
            sourceName: { id in
                guard let record = composition?.repositories.source(QualifiedSourceID(rawValue: id)),
                case .object(let declaration) = record.declaration,
                case .string(let name) = declaration["name"] else { return nil }
                return name
            }, requestRefresh: { await library.refresh() },
            includeAdult: AdultContentSetting.current())
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let summary {
                    summaryView(summary)
                } else if model.rows.isEmpty && !model.isSearching {
                    chooseView
                } else {
                    reviewView
                }
            }
            .navigationTitle("Migrate Sources")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .safeAreaInset(edge: .bottom) {
                if summary == nil && !model.isSearching {
                    Button("Migrate \(model.rows.filter(\.isTicked).count) titles") {
                        showingApply = true
                    }
                        .buttonStyle(.borderedProminent).frame(maxWidth: .infinity).padding()
                        .accessibilityIdentifier("migrateApplyButton")
                        .disabled(model.rows.filter(\.isTicked).isEmpty || isApplying)
                }
            }
            .confirmationDialog("Migrate \(model.rows.filter(\.isTicked).count) titles to \(targetName)?",
                                isPresented: $showingApply, titleVisibility: .visible) {
                Button("Keep \(fromName) as a backup: you can still choose it from “Read from” on each title.") {
                    apply(removing: false)
                }.accessibilityIdentifier("migrateKeep")
                Button(
                    "Remove \(fromName): what you read there still counts. " +
                    "You can add \(fromName) back to any title later.",
                    role: .destructive
                ) {
                    apply(removing: true)
                }.accessibilityIdentifier("migrateRemove")
                Button("Cancel", role: .cancel) {}
            }
            .alert("Add this Source?", isPresented: $showingDifferent) {
                Button("Add anyway") {
                    guard let pendingDifferent else { return }
                    _ = model.pick(pendingDifferent.0, choice: pendingDifferent.1, confirmDifferentEntry: true)
                    self.pendingDifferent = nil
                }
                Button("Cancel", role: .cancel) { pendingDifferent = nil }
            } message: {
                Text("MyAnimeList lists this as a different title, " +
                     "\(pendingDifferent?.1.manga.title ?? ""). Add it anyway?")
            }
        }
        .task(id: runID) {
            guard let fromID, let toID, !model.rows.isEmpty else { return }
            await model.start(from: fromID, to: toID)
        }
        .onDisappear { model.cancel() }
        // Every ten titles, and once when the search ends (finished or cancelled), per design §3.
        .onChange(of: model.searchedCount) { _, value in
            if value > 0 && value.isMultiple(of: 10) && value != model.totalToSearch { announceProgress() }
        }
        .onChange(of: model.isSearching) { wasSearching, isSearching in
            if wasSearching && !isSearching { announceProgress() }
        }
        // A From that the To list can't serve (To == From) moves To to the first valid choice.
        .onChange(of: fromID) { _, _ in
            if !toOptions.contains(where: { $0.id == toID }) { toID = toOptions.first?.id }
        }
        .challengeSheets(nested: true)
    }

    private var chooseView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if model.fromOptions.isEmpty {
                    Text("No saved titles from another Source.")
                    repositoryHint
                } else {
                    Text("From")
                    Picker("From", selection: $fromID) {
                        ForEach(model.fromOptions) { option in
                            Text("\(option.name) · \(option.savedCount) saved titles\(option.isInstalled ? "" : " · Not installed")")
                                .tag(Optional(option.sourceId))
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("migrateFromPicker")
                    Text("To")
                    Picker("To", selection: $toID) {
                        ForEach(toOptions, id: \.id) { source in Text(source.name).tag(Optional(source.id)) }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("migrateToPicker")
                    if toOptions.isEmpty { Text("No other installed Sources."); repositoryHint }
                    Button("Find titles on \(targetName)") {
                        guard let fromID, let toID else { return }
                        model.candidates(from: fromID, to: toID)
                        runID = UUID()
                    }.disabled(fromID == nil || toID == nil)
                }
            }.padding(Gutter.page).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            model.refreshFromOptions()
            chooseDefaults()
        }
    }

    private var repositoryHint: some View {
        Text("Add a repository in Settings to add more places to read.").foregroundStyle(Ink.secondary)
    }

    private var toOptions: [MangaSource] { fromID.map(model.toOptions(from:)) ?? [] }
    private var fromName: String { model.fromOptions.first { $0.sourceId == fromID }?.name ?? "Source" }
    private var targetName: String { toOptions.first { $0.id == toID }?.name ?? "Source" }

    private func chooseDefaults() {
        if fromID == nil { fromID = model.fromOptions.first?.sourceId }
        if toID == nil { toID = toOptions.first?.id }
    }

    private var reviewView: some View {
        VStack(spacing: 8) {
            if model.isSearching {
                Text("Searched \(model.searchedCount) of \(model.totalToSearch)")
                    .accessibilityIdentifier("migrateProgress")
                Button("Cancel") { model.cancel() }
            }
            List {
                section("Ready", status: .ready)
                section("Needs your pick", status: .needsPick)
                section("Not found on \(targetName)", status: .notFound)
                section("Couldn’t check", status: .couldNotCheck)
                section("Not searched", status: .notSearched)
            }
        }
    }

    @ViewBuilder private func section(_ title: String, status: LibraryMigrationStatus) -> some View {
        let rows = model.rows.filter { $0.status == status }
        if !rows.isEmpty {
            Section {
                ForEach(rows) { row in migrationRow(row) }
            } header: {
                Text(title).accessibilityIdentifier("migrateSection.\(statusName(status))")
            }
        }
    }

    private func migrationRow(_ row: LibraryMigrationRow) -> some View {
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                cover(for: row)
                VStack(alignment: .leading, spacing: 5) {
                    Text(row.item.title).font(.headline)
                    if let chosen = row.chosen {
                        Text(chosen.manga.title)
                        Text(chosen.grade.label ?? "Unmatched")
                        chapterCountText(chosen)
                        if chosen.wasRemovedEarlier { Text("Removed earlier") }
                    } else if row.alreadyOnTarget != nil {
                        Text("Already on \(targetName)")
                        Text("Chapter count unknown")
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityLabel(for: row))
                .accessibilityIdentifier("migrateRow.\(row.id.sourceId).\(row.id.mangaId)")
                Spacer(minLength: 4)
                if row.chosen != nil || row.alreadyOnTarget != nil {
                    toggleButton(row)
                }
            }
            alsoInLibraryLink(row)
            retryButton(row)
            if row.status == .needsPick {
                Button("Choose match") { showingChoices = row.id }
                    .sheet(isPresented: Binding(get: { showingChoices == row.id }, set: { if !$0 { showingChoices = nil } })) {
                        choicePicker(row)
                    }
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }

    private func cover(for row: LibraryMigrationRow) -> some View {
        CachedAsyncImage(url: row.item.coverURL) { phase in
            if case .success(let image) = phase {
                image.resizable().scaledToFill()
            } else {
                CoverPlaceholder(showsSpinner: row.item.coverURL != nil)
            }
        }
        .frame(width: 54, height: 76)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .accessibilityHidden(true)
    }

    private func chapterCountText(_ choice: AddSourceRow) -> some View {
        let count = choice.chapterCount.map { "\($0) chapters" } ?? "Chapter count unknown"
        return Text(choice.countRequested ? count : "Chapter count unknown")
    }

    private func accessibilityLabel(for row: LibraryMigrationRow) -> String {
        let group = statusTitle(row.status)
        let choice = row.chosen
        var label = "\(row.item.title), \(group)"
        if choice == nil, row.alreadyOnTarget != nil { label += ", already on \(targetName)" }
        if let choice {
            label += ", match \(choice.manga.title), \(choice.grade.label ?? "Unmatched")"
            if let alternate = choice.matchedAlternateTitle { label += ", also known as \(alternate)" }
            if choice.countRequested, let count = choice.chapterCount { label += ", \(count) chapters" }
        }
        return label
    }

    private func statusTitle(_ status: LibraryMigrationStatus) -> String {
        switch status {
        case .ready: return "Ready"
        case .needsPick: return "Needs your pick"
        case .notFound: return "Not found on \(targetName)"
        case .couldNotCheck: return "Couldn’t check"
        case .notSearched: return "Not searched"
        }
    }

    @ViewBuilder private func toggleButton(_ row: LibraryMigrationRow) -> some View {
        Button { model.toggle(row.id) } label: {
            Image(systemName: row.isTicked ? "checkmark.circle.fill" : "circle")
        }
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityLabel(row.isTicked ? "Selected" : "Not selected")
    }

    @ViewBuilder private func alsoInLibraryLink(_ row: LibraryMigrationRow) -> some View {
        if let other = row.choiceDetails.first(where: { $0.otherWorkTitle != nil }),
           let title = other.otherWorkTitle {
            NavigationLink("Also in your Library as \(title)",
                           destination: MangaDetailView(manga: other.row.manga, registry: registry))
        }
    }

    @ViewBuilder private func retryButton(_ row: LibraryMigrationRow) -> some View {
        if statusIsRetry(row.status) {
            Button("Try again") {
                Task {
                    if let toID { await model.retry(row.id, to: toID) }
                }
            }
        }
    }

    private func choicePicker(_ row: LibraryMigrationRow) -> some View {
        NavigationStack {
            List(row.choiceDetails, id: \.row.id) { choice in
                Button {
                    if choice.otherWorkTitle != nil { return }
                    let result = model.pick(row.id, choice: choice.row)
                    if case .confirmDifferentEntry = result {
                        pendingDifferent = (row.id, choice.row)
                        showingDifferent = true
                    } else if case .picked = result {
                        showingChoices = nil
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(choice.row.manga.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                        if let alternate = choice.row.matchedAlternateTitle { Text("Also known as \(alternate)") }
                        Text(choice.row.grade.label ?? "Unmatched")
                        chapterCountText(choice.row)
                        if let title = choice.otherWorkTitle { Text("Also in your Library as \(title)") }
                        if choice.row.wasRemovedEarlier { Text("Removed earlier") }
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(choice.otherWorkTitle != nil)
                    .accessibilityIdentifier("migrateChoice.\(choice.row.id.sourceId).\(choice.row.id.mangaId)")
            }.navigationTitle("Choose a match")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showingChoices = nil } } }
        }
    }

    private func statusName(_ status: LibraryMigrationStatus) -> String {
        switch status {
        case .ready: return "ready"
        case .needsPick: return "needsPick"
        case .notFound: return "notFound"
        case .couldNotCheck: return "couldNotCheck"
        case .notSearched: return "notSearched"
        }
    }

    private func statusIsRetry(_ status: LibraryMigrationStatus) -> Bool { status == .couldNotCheck }

    private func apply(removing: Bool) {
        guard !isApplying else { return }
        removingOld = removing
        isApplying = true
        Task {
            summary = await model.apply(removingOld: removingOld)
            isApplying = false
        }
    }

    private func announceProgress() {
        AccessibilityNotification.Announcement("Searched \(model.searchedCount) of \(model.totalToSearch)").post()
    }

    private func summaryView(_ summary: LibraryMigrationSummary) -> some View {
        List {
            Section {
                Text("Migrated \(summary.migratedCount) titles.\(summary.skipped.isEmpty ? "" : " \(summary.skipped.count) skipped.")")
                    .accessibilityIdentifier("migrateSummary")
                ForEach(Array(summary.skipped.enumerated()), id: \.offset) { _, item in
                    Text("\(item.title): \(skipReason(item.reason))")
                }
            }
            Button("Done") { dismiss() }
        }
    }

    private func skipReason(_ reason: MigrationSkipReason) -> String {
        switch reason {
        case .belongsToOtherWork(let workID):
            return works.work(workID).map { "now belongs to \($0.displayTitle)" } ??
                "now belongs to another title"
        case .workNotFound:
            return "no longer in your Library"
        }
    }
}
