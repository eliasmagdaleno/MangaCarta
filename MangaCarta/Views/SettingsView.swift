//
//  SettingsView.swift
//  MangaCarta
//

import SwiftUI
import UserNotifications
import UniformTypeIdentifiers

struct SettingsView: View {
    @AppStorage(appearanceStorageKey) private var appearanceRaw = AppearanceMode.system.rawValue
    @AppStorage(RepositorySettingsViewModel.showAdultSourcesKey) private var showAdultSources = false
    @AppStorage(RepositorySettingsViewModel.declaredAgeKey) private var declaredAge = false
    @AppStorage(UpdateNotifier.notificationsEnabledKey) private var notificationsEnabled = true
    /// The graph's registry, not the singleton — the same object the services resolve
    /// through. See `MangaDetailView` for what reading the wrong one costs.
    @EnvironmentObject private var registry: SourceRegistry
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var history: HistoryStore
    @EnvironmentObject private var works: WorkStore
    @EnvironmentObject private var updates: UpdateStateStore
    @Environment(\.extensionComposition) private var extensionComposition
    @Environment(\.extensionStorageError) private var extensionStorageError
    @Environment(\.openURL) private var openURL
    @State private var showingCollectionsSheet = false
    @State private var notificationSummary = NotificationAuthorizationSummary.notRequested
    @State private var showingLocalImporter = false
    @State private var localItemCount = 0
    @State private var localDiskBytes = 0
    @EnvironmentObject private var localImporter: LocalImportViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Gutter.section) {

                    VStack(alignment: .leading, spacing: 14) {
                        InkSectionHeader("Library", eyebrow: "Organization")
                        Button {
                            showingCollectionsSheet = true
                        } label: {
                            HStack {
                                Text("Manage Collections")
                                    .font(.subheadline)
                                    .foregroundStyle(Ink.primary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(Ink.tertiary)
                            }
                            .contentShape(Rectangle())
                            .padding(.horizontal, Gutter.page)
                            .padding(.vertical, 15)
                        }
                        .buttonStyle(.plain)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Ink.surface))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Ink.hairline, lineWidth: 1))
                        .padding(.horizontal, Gutter.page)
                        Button { showingLocalImporter = true } label: {
                            HStack {
                                Label("Local library", systemImage: "externaldrive")
                                    .foregroundStyle(Ink.primary)
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("Import files")
                                        .foregroundStyle(Ink.seal)
                                    Text(localUsageText)
                                        .font(.caption)
                                        .foregroundStyle(Ink.secondary)
                                }
                            }
                            .padding(.horizontal, Gutter.page)
                            .padding(.vertical, 15)
                        }
                        .buttonStyle(.plain)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Ink.surface))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Ink.hairline, lineWidth: 1))
                        .padding(.horizontal, Gutter.page)
                        Text("Imported files are deleted with the app.")
                            .font(.footnote)
                            .foregroundStyle(Ink.tertiary)
                            .padding(.horizontal, Gutter.page)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        InkSectionHeader("Appearance", eyebrow: "Theme")
                        AppearancePicker(selection: $appearanceRaw)
                            .padding(.horizontal, Gutter.page)
                        Text("Follows your device by default. Choose Light or Dark to pin it.")
                            .font(.footnote)
                            .foregroundStyle(Ink.tertiary)
                            .padding(.horizontal, Gutter.page)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        InkSectionHeader("Updates", eyebrow: "Library")
                        VStack(spacing: 0) {
                            aboutRow("In-app", inAppUpdateStatus)
                            Divider().overlay(Ink.hairline).padding(.leading, Gutter.page)
                            aboutRow("System notifications", notificationStatusText)
                            Divider().overlay(Ink.hairline).padding(.leading, Gutter.page)
                            Toggle("Notify about new chapters", isOn: $notificationsEnabled)
                                .font(.subheadline)
                                .tint(Ink.seal)
                                .padding(.horizontal, Gutter.page)
                                .frame(minHeight: 50)
                                .onChange(of: notificationsEnabled) { _, enabled in
                                    if enabled { Task { await requestNotificationsIfNeeded() } }
                                }
                            if effectiveNotificationSummary == .unavailable {
                                Divider().overlay(Ink.hairline).padding(.leading, Gutter.page)
                                Button("Open System Settings", systemImage: "gear", action: openSystemSettings)
                                    .font(.subheadline)
                                    .foregroundStyle(Ink.seal)
                                    .padding(.horizontal, Gutter.page)
                                    .frame(minHeight: 50)
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 14).fill(Ink.surface))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Ink.hairline, lineWidth: 1))
                        .padding(.horizontal, Gutter.page)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        InkSectionHeader("Sources", eyebrow: "Content")
                        // Labelled because there are now two lists of source names in this
                        // section. Leaving the first one bare made it the ambiguous one the
                        // moment the second gained a heading.
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Browse source")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Ink.primary)
                            Text("Which source Home and Search show.")
                                .font(.footnote)
                                .foregroundStyle(Ink.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Gutter.page)

                        VStack(spacing: 0) {
                            let visible = registry.visibleSources(includeAdult: showAdultSources)
                            ForEach(Array(visible.enumerated()), id: \.element.id) { idx, source in
                                if idx > 0 {
                                    Divider().overlay(Ink.hairline).padding(.leading, Gutter.page)
                                }
                                let isActive = source.id == registry.activeSourceID
                                Button {
                                    registry.activeSourceID = source.id
                                } label: {
                                    HStack {
                                        Text(source.name)
                                            .font(.subheadline)
                                            .foregroundStyle(Ink.primary)
                                        Spacer()
                                        if isActive {
                                            Image(systemName: "checkmark").foregroundStyle(Ink.seal)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                    .padding(.horizontal, Gutter.page)
                                    .padding(.vertical, 15)
                                }
                                .buttonStyle(.plain)
                                // Same treatment as the preferred-source rows below, which
                                // had it from the start. Left bare, this row reads as a name
                                // and a stray checkmark — and the checkmark is the half
                                // carrying which source you are actually browsing.
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(source.name)
                                // Namespaced for the same reason the list below is: two lists
                                // of the same source names, and a bare name matches whichever
                                // comes first.
                                .accessibilityIdentifier("browseSource.\(source.name)")
                                .accessibilityAddTraits(isActive ? [.isSelected, .isButton] : .isButton)
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 14).fill(Ink.surface))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Ink.hairline, lineWidth: 1))
                        .padding(.horizontal, Gutter.page)

                        // Hidden when nothing is registered for it to gate — a switch that
                        // changes nothing invites a hunt for the behaviour it is supposed to
                        // control. The stored preference is left alone, so this reappears
                        // with its previous value if an adult source is ever registered.
                        // See ADR-0022.
                        if RepositorySettingsViewModel.shouldShowAdultSourcesToggle(
                            isConfirmed: declaredAge, hasRegisteredAdultSource: registry.hasAdultSource) {
                            Toggle("Show adult sources", isOn: $showAdultSources)
                                .font(.subheadline)
                                .tint(Ink.seal)
                                .padding(.horizontal, Gutter.page)
                                .onChange(of: showAdultSources) { _, newValue in
                                    registry.enforceAdultGating(includeAdult: newValue)
                                    RepositorySettingsViewModel.setAdultSourcesVisible(
                                        newValue, defaults: .standard)
                                    declaredAge = UserDefaults.standard.bool(
                                        forKey: RepositorySettingsViewModel.declaredAgeKey)
                                }
                        }

                        PreferredSourcePicker(sources: registry.visibleSources(
                            includeAdult: showAdultSources))
                    }

                    if let extensionComposition {
                        RepositorySettingsSection(composition: extensionComposition)
                    } else if let extensionStorageError {
                        Text(extensionStorageError)
                            .font(.footnote)
                            .foregroundStyle(Ink.secondary)
                            .padding(.horizontal, Gutter.page)
                            .accessibilityIdentifier("repositorySettings.storeUnreadable")
                    }

                    MALAccountSettingsView()

                    VStack(alignment: .leading, spacing: 14) {
                        InkSectionHeader("About", eyebrow: "Info")
                        VStack(spacing: 0) {
                            aboutRow("Sources", registry.browsableSourceNames.joined(separator: " · "))
                            Divider().overlay(Ink.hairline).padding(.leading, Gutter.page)
                            aboutRow("Version", "0.1 · WIP")
                        }
                        .background(RoundedRectangle(cornerRadius: 14).fill(Ink.surface))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Ink.hairline, lineWidth: 1))
                        .padding(.horizontal, Gutter.page)
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, 40)
            }
            .background(Ink.background)
            .navigationTitle("Settings")
            .task { await refreshNotificationSummary() }
            .sheet(isPresented: $showingCollectionsSheet) {
                CollectionManagementView()
            }
            .fileImporter(isPresented: $showingLocalImporter,
                          allowedContentTypes: [UTType.zip, UTType.mangaCartaCBZ, UTType.pdf],
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { localImporter.importFiles(urls) }
            }
            .overlay(alignment: .top) {
                LocalImportBanner(model: localImporter, onCancel: localImporter.cancel)
                    .padding(.top, 8)
            }
            .task(id: library.items) { await refreshLocalUsage() }
        }
    }

    private func aboutRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Ink.primary)
            Spacer()
            Text(value)
                .font(.inkMono(12, weight: .medium))
                .foregroundStyle(Ink.secondary)
        }
        .padding(.horizontal, Gutter.page)
        .padding(.vertical, 15)
    }

    private func refreshLocalUsage() async {
        guard let local = registry.source(id: LocalSource.sourceID) as? LocalSource else { return }
        let usage = await local.store.usage()
        localItemCount = usage.count
        localDiskBytes = usage.bytes
    }

    private var localUsageText: String {
        let count = localItemCount == 1 ? "1 item" : "\(localItemCount) items"
        let size = ByteCountFormatter.string(fromByteCount: Int64(localDiskBytes), countStyle: .file)
        return "\(count) · \(size)"
    }

    private var inAppUpdateStatus: String {
        let summaries = LibraryUpdatesPresentation.summaries(
            works: works, library: library, history: history, updates: updates)
        guard !library.items.isEmpty else { return "No saved titles" }
        guard summaries.contains(where: { $0.freshness != .notChecked }) else { return "Not checked yet" }
        let count = summaries.count(where: { $0.newlyDiscoveredCount > 0 })
        return count == 1 ? "1 title with updates" : "\(count) titles with updates"
    }

    private var notificationStatusText: String {
        switch effectiveNotificationSummary {
        case .notRequested: "Not requested"
        case .enabled: "Allowed"
        case .unavailable: "Unavailable"
        }
    }

    private func refreshNotificationSummary() async {
        if let fixtureSummary = Self.uiTestNotificationSummary {
            notificationSummary = fixtureSummary
            return
        }
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        switch status {
        case .authorized, .provisional, .ephemeral:
            notificationSummary = .enabled
        case .notDetermined:
            notificationSummary = .notRequested
        default:
            notificationSummary = .unavailable
        }
    }

    private var effectiveNotificationSummary: NotificationAuthorizationSummary {
        Self.uiTestNotificationSummary ?? notificationSummary
    }

    private static var uiTestNotificationSummary: NotificationAuthorizationSummary? {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("-uitest-updates-state") ? .notRequested : nil
#else
        nil
#endif
    }

    private func requestNotificationsIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        if await center.notificationSettings().authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .badge, .sound])
        }
        await refreshNotificationSummary()
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}

private struct RepositorySettingsSection: View {
    @StateObject private var model: RepositorySettingsViewModel
    @ObservedObject private var repositories: RepositoryStore
    @State private var repositoryURL = ""

    init(composition: AppComposition.ExtensionComposition) {
        _model = StateObject(wrappedValue: RepositorySettingsViewModel(composition: composition))
        _repositories = ObservedObject(wrappedValue: composition.repositories)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            InkSectionHeader("Repositories", eyebrow: "Extensions")
            HStack {
                TextField("https://example.org/index.json", text: $repositoryURL)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .accessibilityIdentifier("repositorySettings.url")
                Button("Add") { model.addRepository(repositoryURL) }
                    .accessibilityIdentifier("repositorySettings.add")
            }
            .padding(.horizontal, Gutter.page)

            if model.storeUnreadable {
                Text("Installed Sources could not be read. Nothing was removed.")
                    .font(.footnote).foregroundStyle(Ink.secondary)
                    .accessibilityIdentifier("repositorySettings.storeUnreadable")
            }
            ForEach(repositories.repositories.filter { $0.state == .active }) { repository in
                VStack(alignment: .leading, spacing: 8) {
                    Text(repository.name).font(.subheadline.weight(.semibold))
                    Text(RepositorySettingsViewModel.isBundled(repository)
                         ? "Shipped with the app; updates arrive with app updates."
                         : repository.indexURL.absoluteString)
                        .font(.caption).foregroundStyle(Ink.secondary)
                    ForEach(repositories.sources(in: repository.id), id: \.qualifiedId) { source in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(source.localId)
                                Text(source.state.rawValue).font(.caption).foregroundStyle(Ink.secondary)
                            }
                            Spacer()
                            if source.state == .uninstalled {
                                Button("Install") { model.install(localId: source.localId, from: repository.id) }
                            } else {
                                if model.canReconnect(source) {
                                    Button("Reconnect prior data") { model.offerMigration(for: source) }
                                }
                                if let offered = model.composition.installer.listings[repository.id]?.availableUpdates[source.bundleId] {
                                    Button("Update") { model.run { try await model.composition.installer.updateBundle(source.bundleId, in: repository.id) } }
                                        .accessibilityLabel("Update to version \(offered)")
                                }
                                Button(source.state == .disabled ? "Enable" : "Disable") {
                                    model.run {
                                        if source.state == .disabled { try model.composition.installer.enable(source.qualifiedId) }
                                        else { try model.composition.installer.disable(source.qualifiedId) }
                                    }
                                }
                                Button("Uninstall") { model.run { try model.composition.installer.uninstall(source.qualifiedId) } }
                            }
                        }
                    }
                    ForEach(model.availableSources[repository.id] ?? [], id: \.path) { entry in
                        if let localId = entry.localId,
                           repositories.source(ExtensionInstaller.qualifiedID(repositoryID: repository.id, localId: localId)) == nil {
                            HStack {
                                Text(entry.declaration?.name ?? localId)
                                Spacer()
                                if entry.declaration != nil {
                                    Button("Install") {
                                        model.install(localId: localId, from: repository.id)
                                    }
                                    .accessibilityIdentifier("repositorySettings.install.\(localId)")
                                } else {
                                    Text("Not installable").font(.caption)
                                }
                            }
                        }
                    }
                    HStack {
                        Button("Refresh") { model.refreshRepository(repository.id) }
                        if !RepositorySettingsViewModel.isBundled(repository) {
                            Button("Change URL") {
                                guard let url = URL(string: repositoryURL), url.scheme?.lowercased() == "https" else {
                                    model.errorMessage = "Enter a valid HTTPS repository URL."
                                    return
                                }
                                model.run { _ = try await model.composition.installer.changeRepositoryURL(repository.id, to: url) }
                            }
                            Button("Remove") { model.run { try model.composition.installer.removeRepository(repository.id) } }
                        }
                    }
                }
                .padding(Gutter.page)
                .background(RoundedRectangle(cornerRadius: 14).fill(Ink.surface))
                .padding(.horizontal, Gutter.page)
            }
            if let error = model.errorMessage {
                Text(error).font(.footnote).foregroundStyle(Ink.secondary)
                    .accessibilityIdentifier("repositorySettings.error")
            }
            if let status = model.statusMessage {
                Text(status).font(.footnote).foregroundStyle(Ink.secondary)
            }
        }
        .task { model.refreshStoreStatus() }
        .sheet(item: Binding(get: { model.pendingAcknowledgement },
                             set: { if $0 == nil { model.answerAgeGate(false) } })) { item in
            VStack(spacing: 16) {
                Text(item.asksForAge ? "Confirm your age" : "Adult Source").font(.title2.weight(.semibold))
                Text(RepositorySettingsViewModel.ageConfirmationCopy(for: item.acknowledgement,
                                                                     asksForAge: item.asksForAge))
                if item.asksForAge {
                    Button("I am 18 or over") { model.answerAgeGate(true) }
                        .accessibilityIdentifier("repositorySettings.confirmAge")
                } else {
                    Button("Install") { model.answerAgeGate(true) }
                        .accessibilityIdentifier("repositorySettings.continueInstall")
                }
                Button("Cancel") { model.answerAgeGate(false) }
            }.padding(24).presentationDetents([.medium])
        }
        .alert("Reconnect previous library data?",
               isPresented: Binding(get: { model.pendingMigration != nil },
                                    set: { if !$0 { model.answerMigration(false) } })) {
            Button("Reconnect next launch") { model.answerMigration(true) }
            Button("Not now", role: .cancel) { model.answerMigration(false) }
        } message: {
            if let pending = model.pendingMigration {
                Text("Move previous \(pending.record.localId) library, reading history and source choices to the Source installed from \(pending.repositoryName). Nothing is removed if you decline.")
            }
        }
    }
}

/// Three seal-highlighted cards: System / Light / Dark. The signature control
/// for the dark-mode feature.
/// The fulfillment preference (ADR-0004 Amendment 1), which is **not** the browse source
/// above it. Browsing is "whose feed am I looking at"; this is "when several sources have
/// the same manga, whose scans do I want". Two lists of source names one after another
/// would be confusing without the caption saying which question each answers.
private struct PreferredSourcePicker: View {
    let sources: [MangaSource]
    @EnvironmentObject private var preferences: SourcePreferenceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preferred source")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Ink.primary)
            Text("When several sources carry the same manga, read it from this one. "
                 + "It only settles ties — a source with more chapters still wins.")
                .font(.footnote)
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                // "No preference" is a real row rather than an absent selection. Without it
                // there is no way back to the automatic behaviour once a source is picked,
                // and the default would be indistinguishable from a deliberate choice.
                row(title: "No preference", detail: "Prefer MangaDex", isSelected: preferences.primarySourceId == nil) {
                    preferences.primarySourceId = nil
                }
                ForEach(sources, id: \.id) { source in
                    Divider().overlay(Ink.hairline).padding(.leading, Gutter.page)
                    row(title: source.name, detail: nil,
                        isSelected: preferences.primarySourceId == source.id) {
                        preferences.primarySourceId = source.id
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 14).fill(Ink.surface))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Ink.hairline, lineWidth: 1))
        }
        .padding(.horizontal, Gutter.page)
        .padding(.top, 6)
    }

    private func row(title: String, detail: String?, isSelected: Bool,
                     select: @escaping () -> Void) -> some View {
        Button(action: select) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .foregroundStyle(Ink.primary)
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(Ink.secondary)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark").foregroundStyle(Ink.seal)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, Gutter.page)
            .padding(.vertical, 15)
        }
        .buttonStyle(.plain)
        // One element, one sentence. Left to itself the row reads as two separate texts
        // plus a bare checkmark, and the checkmark is the half that carries the state.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(detail.map { "\(title), \($0)" } ?? title)
        // Namespaced because Settings shows two lists of source names — the browse source
        // above, this preference below — and a bare name matches the wrong one.
        .accessibilityIdentifier("preferredSource.\(title)")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

private struct AppearancePicker: View {
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 10) {
            ForEach(AppearanceMode.allCases) { mode in
                let isSelected = selection == mode.rawValue
                Button {
                    withAnimation(.snappy(duration: 0.2)) { selection = mode.rawValue }
                } label: {
                    VStack(spacing: 10) {
                        Image(systemName: mode.symbol)
                            .font(.system(size: 22, weight: .regular))
                            .foregroundStyle(isSelected ? Ink.seal : Ink.secondary)
                        Text(mode.label)
                            .font(.inkMono(11, weight: .semibold))
                            .tracking(0.5)
                            .foregroundStyle(isSelected ? Ink.primary : Ink.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(isSelected ? Ink.sealSoft : Ink.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(isSelected ? Ink.seal : Ink.hairline,
                                          lineWidth: isSelected ? 1.5 : 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

#Preview {
    let works = WorkStore()
    SettingsView()
        .environmentObject(LibraryStore(works: works))
        .environmentObject(HistoryStore(works: works))
        .environmentObject(works)
        .environmentObject(LocalImportViewModel())
        .environmentObject(UpdateStateStore(works: works))
}
