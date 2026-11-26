//
//  MangaCartaApp.swift
//  MangaCarta
//
//  Created by Elias Magdaleno on 5/31/24.
//

import SwiftUI
import UserNotifications

@main
struct MangaCartaApp: App {
    // Persisted appearance choice; drives the whole app's color scheme.
    @AppStorage(appearanceStorageKey) private var appearanceRaw = AppearanceMode.system.rawValue

    @Environment(\.scenePhase) private var scenePhase

    // App-wide stores + the recommendation engine, all owned here so the engine shares
    // the exact same store instances the rest of the app writes to.
    @StateObject private var library: LibraryStore
    @StateObject private var history: HistoryStore
    @StateObject private var taste: TasteProfileStore
    @StateObject private var works: WorkStore
    @StateObject private var engine: RecommendationEngine
    /// Owned here so it lives as long as the app and shares the one `WorkStore`, but
    /// deliberately **not** put in the environment: it publishes nothing, so a view that
    /// could reach it could only misuse it (ADR-0010).
    @StateObject private var queue: MetadataUpgradeQueue
    @StateObject private var updates: UpdateStateStore
    /// Observable, and injected into the environment for the Settings account section.
    @StateObject private var account: MALAccountStore
    /// Fulfillment (ADR-0004). Both are observable and both are written from the UI —
    /// Settings sets the primary source, the detail page pins a Listing — so both belong
    /// in the environment rather than staying inside the composition.
    @StateObject private var sourcePreferences: SourcePreferenceStore
    @StateObject private var readingModes: ReadingModeStore
    @StateObject private var fulfillment: FulfillmentCoordinator
    @StateObject private var workSources: WorkSourcesCoordinator
    @StateObject private var analyticsConsent: AnalyticsConsentStore
    @StateObject private var analytics: AnalyticsRecorder
    /// The graph's registry, so views resolve sources from the same one the services do.
    @StateObject private var registry: SourceRegistry
    @StateObject private var localImporter: LocalImportViewModel
    /// Where a tapped new-chapter notification lands; the Library tab observes it.
    @StateObject private var workNavigator: WorkNavigator
    @StateObject private var notificationPrompt: NotificationAuthorizationPrompt

    /// Plain properties rather than `@StateObject` — neither publishes anything, so a view
    /// that could reach one could only misuse it (ADR-0010). See `AppComposition` for why
    /// they are held for the app's lifetime rather than built per rail build.
    private let vocabularyStore: TagVocabularyStore
    private let poolStore: AniListPoolStore
    /// Same reason as the two above: the coordinator publishes nothing. It is held for the
    /// app's lifetime because the drain is its own serial task, and a rebuilt coordinator
    /// would be a second one.
    private let malProgress: MALProgressCoordinator
    private let analyticsUploader: AnalyticsUploader?
    private let refresh: LibraryRefreshCoordinator
    private let notifier: UpdateNotifier
    private let scheduler: UpdateScheduler
    /// Held because `UNUserNotificationCenter.delegate` is weak.
    private let notificationDelegate: UpdateNotificationDelegate
    /// Installed Sources (Phase 4). Held for the app's lifetime so the registrar keeps
    /// `registry` current; views reach the sources through `registry`, never this.
    private let extensions: AppComposition.ExtensionComposition?
    private let extensionStorageError: String?
    private let imageCache: ImageCache
    private let malDetailStore: MALDetailStore
    private let malSourceChoiceStore: MALSourceChoiceStore
    private let malDetailFetch: @Sendable (Int) async throws -> MyAnimeListMangaDetail
    private let entityResolutionStore: EntityResolutionStore
    private let listingCountCache: ListingCountCache
    private let analyticsRegion: String?

    // swiftlint:disable function_body_length cyclomatic_complexity
    /// The graph itself lives in `AppComposition`, where it can be built against temp
    /// storage and asserted on. This initializer does nothing but adopt what it built.
    init() {
        // A UI test asserting the signed-out MyAnimeList section must not read this
        // device's real account, or it passes on fresh CI and fails on any machine that
        // has signed in. `#if DEBUG` so no release build can be talked out of its account.
        var ephemeralCredentials: MALCredentialStore?
        var ephemeralPreferences: MALAccountPreferenceStore?
        var defaults = UserDefaults.standard
        var directory = WorkStore.applicationSupportDirectory()
        var updateRegistry: SourceRegistry?
        var repositoryTransport: (any RepositoryTransport)?
        var fixtureDetailStore: MALDetailStore?
        var fixtureChoiceStore: MALSourceChoiceStore?
        var fixtureEntityStore: EntityResolutionStore?
        var fixtureCountDirectory: URL?
        var analyticsRegion: String?
        var fixtureDetailFetch: @Sendable (Int) async throws -> MyAnimeListMangaDetail = {
            try await MyAnimeListAPI.mangaDetail(id: $0)
        }
        analyticsRegion = nil
#if DEBUG
        if LibraryMigrateUITestFixture.isRequested {
            let storage = LibraryMigrateUITestFixture.storage()
            defaults = storage.defaults
            directory = storage.directory
            fixtureCountDirectory = storage.directory.appendingPathComponent("ListingCounts")
            updateRegistry = LibraryMigrateUITestFixture.registry(defaults: defaults)
            fixtureDetailFetch = { id in
                MyAnimeListMangaDetail(id: id, title: "Fixture title", synopsis: "", mainPicture: nil,
                                       genres: [], relatedManga: [], recommendations: [], nsfw: .white,
                                       alternativeTitles: .init(synonyms: [], en: nil, ja: nil))
            }
        } else if let region = AnalyticsUITestFixture.region {
            let storage = AnalyticsUITestFixture.storage()
            defaults = storage.defaults
            directory = storage.directory
            analyticsRegion = region
        } else if let fixtureState = MALHubUITestFixture.state {
            let storage = MALHubUITestFixture.storage()
            defaults = storage.defaults
            directory = storage.directory
            fixtureDetailStore = storage.detailStore
            fixtureChoiceStore = storage.choiceStore
            fixtureEntityStore = storage.entityStore
            fixtureCountDirectory = storage.directory.appendingPathComponent("ListingCounts")
            fixtureDetailFetch = MALHubUITestFixture.fetchDetail
            updateRegistry = MALHubUITestFixture.registry(state: fixtureState, defaults: defaults)
        } else if TitleSourcesUITestFixture.isRequested {
            let storage = TitleSourcesUITestFixture.storage()
            defaults = storage.defaults
            directory = storage.directory
            fixtureEntityStore = storage.entityStore
            fixtureDetailFetch = TitleSourcesUITestFixture.fetchDetail
            fixtureCountDirectory = storage.directory.appendingPathComponent("ListingCounts")
            updateRegistry = TitleSourcesUITestFixture.registry(defaults: defaults)
        } else if ProcessInfo.processInfo.arguments.contains("-uitest-local-import") {
            let storageID = ProcessInfo.processInfo.environment["MANGACARTA_UI_TEST_STORAGE_ID"] ?? UUID().uuidString
            let suite = "local-import-ui-test-\(storageID)"
            defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("MangaCarta-LocalImportUITest-\(storageID)", isDirectory: true)
            try? FileManager.default.removeItem(at: directory)
            let local = LocalLibraryStore(root: directory.appendingPathComponent("LocalLibrary"))
            updateRegistry = SourceRegistry(sources: [LocalSource(store: local)])
        } else if ProcessInfo.processInfo.arguments.contains("-uitest-mal-signed-out") {
            (ephemeralCredentials, ephemeralPreferences) = AppComposition.ephemeralMALAccount()
        } else if let state = Self.uiTestAccountState {
            // The other account states, on the same ephemeral stores and for the same
            // reason: a screenshot of "signed in" must not be of the real account.
            (ephemeralCredentials, ephemeralPreferences) = AppComposition.seededMALAccount(state)
        }
        if let updateState = UpdatesUITestFixture.state {
            let storage = UpdatesUITestFixture.freshStorage(for: updateState)
            defaults = storage.defaults
            directory = storage.directory
            // The picker only exists when two sources are registered, so this state is
            // the one that registers a second.
            updateRegistry = updateState == .twoListings
                ? SourceRegistry(sources: [UpdatesUITestSource(), UpdatesUITestAltSource()])
                : updateState == .notificationActions
                ? SourceRegistry(sources: [NotificationActionsUITestSource()])
                : updateState.usesUpdatesScreenSources
                ? SourceRegistry(sources: [UpdatesScreenUITestSource(), FailingUpdatesUITestSource()])
                : SourceRegistry(sources: [UpdatesUITestSource()])
        }
        if ProcessInfo.processInfo.arguments.contains("-uitest-zero-sources") {
            updateRegistry = SourceRegistry(sources: [])
        }
        if ProcessInfo.processInfo.arguments.contains("-uitest-repository-settings") {
            let suite = "repository-settings-ui-test"
            defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            UserDefaults.standard.removeObject(forKey: RepositorySettingsViewModel.declaredAgeKey)
            UserDefaults.standard.removeObject(forKey: RepositorySettingsViewModel.showAdultSourcesKey)
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("MangaCarta-RepositorySettingsUITest", isDirectory: true)
            try? FileManager.default.removeItem(at: directory)
            repositoryTransport = AppComposition.RepositorySettingsUITestTransport(
                includesReportingSource: ProcessInfo.processInfo.arguments.contains("-uitest-repository-reports"))
        }
#endif
        let analyticsNoticeSuppressed = ProcessInfo.processInfo.arguments.contains {
            $0.hasPrefix("-uitest-")
        } && analyticsRegion == nil
        let composed = AppComposition(defaults: defaults, directory: directory,
                                      malCredentials: ephemeralCredentials,
                                      malPreferences: ephemeralPreferences,
                                      entityResolutionStore: fixtureEntityStore,
                                      malDetailStore: fixtureDetailStore,
                                      malDetailFetch: fixtureDetailFetch,
                                      registry: updateRegistry,
                                      repositoryTransport: repositoryTransport,
                                      malSourceChoiceStore: fixtureChoiceStore,
                                      listingCountDirectory: fixtureCountDirectory,
                                      analyticsNoticeSuppressed: analyticsNoticeSuppressed)
#if DEBUG
        if MALHubUITestFixture.state != nil {
            MALHubUITestFixture.seed(composed)
        }
        if LibraryMigrateUITestFixture.isRequested {
            LibraryMigrateUITestFixture.seed(composed)
        }
        if TitleSourcesUITestFixture.isRequested {
            TitleSourcesUITestFixture.seed(composed)
        }
        if let updateState = UpdatesUITestFixture.state {
            UpdatesUITestFixture.seed(updateState, in: composed)
        }
        if let url = LiveUITestRepositoryInstall.requestedURL, let extensions = composed.extensions {
            let registry = composed.registry
            Task { await LiveUITestRepositoryInstall.run(url: url, extensions: extensions, registry: registry) }
        }
#endif
        self.vocabularyStore = composed.vocabularyStore
        self.poolStore = composed.poolStore
        self.malProgress = composed.malProgress
        self.analyticsUploader = composed.analyticsUploader
        self.refresh = composed.refresh
        self.notifier = composed.notifier
        self.scheduler = composed.scheduler
        self.notificationDelegate = composed.notificationDelegate
        _workNavigator = StateObject(wrappedValue: composed.workNavigator)
        _notificationPrompt = StateObject(wrappedValue: composed.notificationPrompt)
        // Before launch finishes, so a tap that launched the app is delivered (ADR-0021).
        UNUserNotificationCenter.current().delegate = composed.notificationDelegate
        composed.notifier.registerCategories()
        self.extensions = composed.extensions
        self.extensionStorageError = composed.extensionStorageError
        self.imageCache = composed.imageCache
        self.malDetailStore = composed.malDetailStore
        self.malSourceChoiceStore = composed.malSourceChoiceStore
        self.malDetailFetch = composed.malDetailFetch
        self.analyticsRegion = analyticsRegion
        self.entityResolutionStore = composed.entityResolutionStore; self.listingCountCache = composed.listingCounts
        _library = StateObject(wrappedValue: composed.library)
        _history = StateObject(wrappedValue: composed.history)
        _taste = StateObject(wrappedValue: composed.taste)
        _works = StateObject(wrappedValue: composed.works)
        _queue = StateObject(wrappedValue: composed.queue)
        _updates = StateObject(wrappedValue: composed.updates)
        _engine = StateObject(wrappedValue: composed.engine)
        _account = StateObject(wrappedValue: composed.account)
        _sourcePreferences = StateObject(wrappedValue: composed.sourcePreferences)
        _readingModes = StateObject(wrappedValue: composed.readingModes)
        _fulfillment = StateObject(wrappedValue: composed.fulfillment)
        _workSources = StateObject(wrappedValue: composed.workSources)
        _analyticsConsent = StateObject(wrappedValue: composed.analyticsConsent)
        _analytics = StateObject(wrappedValue: composed.analytics)
        _registry = StateObject(wrappedValue: composed.registry)
        let localImporter = LocalImportViewModel()
        localImporter.configure(registry: composed.registry, library: composed.library, works: composed.works,
                                readingModes: composed.readingModes)
        localImporter.importFinished = composed.analytics.localImportFinished
        _localImporter = StateObject(wrappedValue: localImporter)
        scheduler.register()
    }
    // swiftlint:enable function_body_length cyclomatic_complexity

#if DEBUG
    /// `-uitest-mal-state <name>`, or nil. Its own property so the initializer and the
    /// launch task read the same answer.
    private static var uiTestAccountState: AppComposition.MALUITestAccountState? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-uitest-mal-state"),
              arguments.indices.contains(index + 1) else { return nil }
        return AppComposition.MALUITestAccountState(rawValue: arguments[index + 1])
    }
#endif

    private var appearance: AppearanceMode {
        AppearanceMode(rawValue: appearanceRaw) ?? .system
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(Ink.seal)
                .environmentObject(library)
                .environmentObject(history)
                .environmentObject(taste)
                .environmentObject(works)
                .environmentObject(updates)
                .environmentObject(engine)
                .environmentObject(account)
                .environmentObject(sourcePreferences)
                .environmentObject(readingModes)
                .environmentObject(fulfillment)
                .environmentObject(workSources)
                .environmentObject(analyticsConsent)
                .environmentObject(analytics)
                .environmentObject(registry)
                .environmentObject(localImporter)
                .environmentObject(workNavigator)
                .environment(\.extensionComposition, extensions)
                .environment(\.extensionStorageError, extensionStorageError)
                .environment(\.imageCache, imageCache)
                .environment(\.malDetailStore, malDetailStore)
                .environment(\.malSourceChoiceStore, malSourceChoiceStore)
                .environment(\.malDetailFetch, malDetailFetch)
                .environment(\.entityResolutionStore, entityResolutionStore)
                .environment(\.listingCountCache, listingCountCache)
                .sheet(isPresented: $notificationPrompt.isPresented,
                       onDismiss: notificationPrompt.dismissed) {
                    NotificationExplainerSheet(
                        onContinue: notificationPrompt.continueToAuthorization,
                        onNotNow: notificationPrompt.notNow)
                }
                .preferredColorScheme(appearance.colorScheme)
                // `onChange` does not fire for the initial value, so launch needs its
                // own start. `start()` is idempotent, so the `.active` case below
                // arriving first, later, or not at all is all the same.
                .task {
                    let local = (registry.source(id: LocalSource.sourceID) as? LocalSource)?.store ?? .shared
                    await LocalSeriesMigration.run(local: local, library: library, history: history, works: works)
#if DEBUG
                    if let analyticsRegion {
                        analyticsConsent.updateRegion(storefrontCountryCode: analyticsRegion,
                                                      localeRegionCode: nil)
                    } else {
                        let region = await AnalyticsRegionPolicy.currentRegion()
                        analyticsConsent.updateRegion(storefrontCountryCode: region.storefrontCountryCode,
                                                      localeRegionCode: region.localeRegionCode)
                    }
                    await Self.importUITestFixtureIfRequested(library: library, works: works, registry: registry,
                                                              readingModes: readingModes)
                    if UpdatesUITestFixture.state == nil {
                        queue.start()
                        refresh.startForeground { [notifier] events in
                            await notifier.schedule(events)
                        }
                    }
#else
                    let region = await AnalyticsRegionPolicy.currentRegion()
                    analyticsConsent.updateRegion(storefrontCountryCode: region.storefrontCountryCode,
                                                  localeRegionCode: region.localeRegionCode)
                    queue.start()
                    refresh.startForeground { [notifier] events in
                        await notifier.schedule(events)
                    }
#endif
                    // Rebuilds the account from disk before anything asks whether the user
                    // is signed in, then drains whatever a previous session left queued.
                    account.restore()
#if DEBUG
                    // After `restore()`, so these sit on top of a real signed-in account
                    // rather than replacing one.
                    switch Self.uiTestAccountState {
                    case .refreshing:
                        account.refreshBegan()
                    case .accountSwitch:
                        account.seedPendingAccountSwitchForUITesting(previousUserID: 999_999,
                                                                     pendingCount: 3)
                    case .signedIn, .reauthorizationRequired, .none:
                        break
                    }
#endif
                    malProgress.start()
                    // Collapses the AniList pool's cold start from three rail builds to
                    // two. Without it: build 1 finds no vocabulary and returns `[]` before
                    // seeding at all, build 2 seeds but misses the pool, build 3 finally
                    // has one — and since `load()` is once-per-session, "build" means app
                    // launch. This is an optimization on top of the provider's own kick,
                    // never a replacement for it: that one is the correctness path for a
                    // `Caches/` eviction mid-session, and `refreshIfNeeded` is idempotent,
                    // so both firing is a no-op. Fire-and-forget, so it never blocks Home —
                    // the concern `TagVocabularyStore.cachedVocabulary` is written against.
#if DEBUG
                    if UpdatesUITestFixture.state == nil {
                        await vocabularyStore.refreshIfNeeded()
                    }
#else
                    await vocabularyStore.refreshIfNeeded()
#endif
                    analytics.vocabulary = await vocabularyStore.cachedVocabulary()
                    await analyticsUploader?.drainIfDue()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                analytics.appActive()
                Task { await analyticsUploader?.drainIfDue() }
#if DEBUG
                guard UpdatesUITestFixture.state == nil else { break }
#endif
                queue.start()
                malProgress.start()
                refresh.startForeground { [notifier] events in
                    await notifier.schedule(events)
                }
            case .background:
                // Stop before flushing: cancellation is what guarantees no attempt
                // record is written after `queue.flush()` has already run.
                queue.stop()
                // Stop before flushing for the same reason as the metadata queue: no
                // completed request may dirty update state after its final persistence.
                refresh.stopForeground()
                // Same order, same reason: the drain is stopped before the outbox is
                // flushed, so no attempt can be written after the flush has run.
                malProgress.stop()
                // `WorkStore` debounces its saves, and `mint` runs on every page turn —
                // so a reading session that ends by backgrounding the app would otherwise
                // lose whatever the pending timer hadn't written yet (ADR-0007).
                works.flush()
                queue.flush()
                updates.flush()
                // Same reason, one layer up: reading position is throttled while scrolling,
                // and a webtoon session that ends by backgrounding would lose the last
                // couple of seconds of it (ADR-0014).
                history.flush()
                malProgress.flush()
                scheduler.scheduleNext(from: Date())
            default:
                // `.inactive` is NOT a stop signal (ADR-0010). It arrives for a
                // notification banner or the app switcher, and tearing the pass down
                // several times a minute would lose the skip set for no reason.
                break
            }
        }
    }

#if DEBUG
    /// Hermetic UI runs can ship a CBZ beside the test bundle; the app still exercises the
    /// exact store import path used by the Files picker rather than a UI-only shortcut.
    private static func importUITestFixtureIfRequested(library: LibraryStore, works: WorkStore,
                                                       registry: SourceRegistry,
                                                       readingModes: ReadingModeStore) async {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-uitest-import-fixture"),
              arguments.indices.contains(index + 1),
              let encoded = ProcessInfo.processInfo.environment["MANGACARTA_UI_FIXTURE_BASE64"],
              let data = Data(base64Encoded: encoded),
              registry.source(id: LocalSource.sourceID) is LocalSource else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(arguments[index + 1] + ".cbz")
        try? data.write(to: url, options: .atomic)
        let importer = LocalImportViewModel()
        importer.configure(registry: registry, library: library, works: works, readingModes: readingModes)
        await importer.importFilesAndWait([url])
    }
#endif
}

#if DEBUG
/// Launch-only data for the ADR-0021 UI evidence. It uses the real stores and refresh
/// coordinator with a local source, so an XCUITest never treats live source availability as
/// an update signal and never inherits the seeded simulator's library or permissions.
enum UpdatesUITestFixture {
    enum State: String {
        case empty
        case notChecked = "not-checked"
        case refreshComplete = "refresh-complete"
        case updatesFilter = "updates-filter"
        /// One Work carrying two Listings, for the detail-page source picker (ADR-0004).
        /// Reached through the same `-uitest-updates-state` argument: the flag's name
        /// predates its second use, and one seeding path with isolated storage is worth
        /// more than a tidier spelling.
        case twoListings = "two-listings"
        case notificationActions = "notification-actions"
        /// The Updates screen (spec 2026-11-09, slice 2): one Work whose Source answers,
        /// with a discovered chapter it no longer lists, and one whose Source always fails.
        case updatesScreen = "updates-screen"
        /// `updatesScreen` plus four more updated Works, one past Home's summary limit, so
        /// Home shows its "View all" link (slice 3).
        case updatesHomeLink = "updates-home-link"
        /// `updatesHomeLink` plus a real notification for its last Work, scheduled when the
        /// app enters the background, for the notification-tap route (slice 3).
        case notificationTap = "notification-tap"

        /// The states built on the Updates screen's two Sources.
        var usesUpdatesScreenSources: Bool {
            self == .updatesScreen || self == .updatesHomeLink || self == .notificationTap
        }
    }

    static var state: State? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-uitest-updates-state"),
              arguments.indices.contains(index + 1) else { return nil }
        return State(rawValue: arguments[index + 1])
    }

    static func freshStorage(for state: State) -> (defaults: UserDefaults, directory: URL) {
        let suite = "updates-ui-test.\(state.rawValue)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MangaCarta-UpdatesUITest-\(state.rawValue)", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        return (defaults, directory)
    }

    @MainActor
    static func seed(_ state: State, in composition: AppComposition) {
        guard state != .empty else { return }
        let sourceID = state == .notificationActions
            ? NotificationActionsUITestSource.sourceID
            : state.usesUpdatesScreenSources ? UpdatesScreenUITestSource.sourceID : UpdatesUITestSource.sourceID
        let title = state == .notificationActions ? "Notification Action Title" : "Fixture Update Title"
        let manga = Manga(id: "update-fixture", sourceId: sourceID,
                          title: title, description: "", status: "ongoing",
                          year: nil, coverURL: nil, malId: nil)
        composition.library.toggle(manga)
        let workId = composition.works.mint(from: manga)
        let listing = ListingKey(manga)

        switch state {
        case .empty, .notChecked, .refreshComplete:
            break
        case .updatesFilter:
            _ = composition.updates.absorb(workId: workId, listing: listing,
                                           rawNumbers: ["1"], now: .now)
            _ = composition.updates.absorb(workId: workId, listing: listing,
                                           rawNumbers: ["1", "2"], now: .now)
        case .twoListings:
            // A second source's copy of the same manga, merged onto the same Work — which
            // is the shape entity resolution leaves behind when two sources converge, and
            // the only shape in which the picker has anything to offer.
            let alternate = Manga(id: "alt-fixture", sourceId: UpdatesUITestAltSource.sourceID,
                                  title: "Fixture Update Title", description: "",
                                  status: "ongoing", year: nil, coverURL: nil, malId: nil)
            let alternateWork = composition.works.mint(from: alternate)
            composition.works.merge(alternateWork, into: workId)
        case .updatesScreen, .updatesHomeLink, .notificationTap:
            // Chapters 2–4 are new; the Source lists 1–3, so 4 has no chapter behind it.
            _ = composition.updates.absorb(workId: workId, listing: listing,
                                           rawNumbers: ["1"], now: .now)
            _ = composition.updates.absorb(workId: workId, listing: listing,
                                           rawNumbers: ["1", "2", "3", "4"], now: .now)
            let failing = Manga(id: "failing-fixture", sourceId: FailingUpdatesUITestSource.sourceID,
                                title: "Second Fixture Title", description: "", status: "ongoing",
                                year: nil, coverURL: nil, malId: nil)
            composition.library.toggle(failing)
            let failingWork = composition.works.mint(from: failing)
            let yesterday = Date.now.addingTimeInterval(-86_400)
            _ = composition.updates.absorb(workId: failingWork, listing: ListingKey(failing),
                                           rawNumbers: ["1"], now: yesterday)
            _ = composition.updates.absorb(workId: failingWork, listing: ListingKey(failing),
                                           rawNumbers: ["1", "2"], now: yesterday)
            var extraWorks: [(work: WorkID, manga: Manga)] = []
            if state == .updatesHomeLink || state == .notificationTap {
                let earlier = Date.now.addingTimeInterval(-3 * 86_400)
                for index in 1...UpdateTuning.homeSummaryLimit - 1 {
                    let extra = Manga(id: "extra-fixture-\(index)", sourceId: UpdatesScreenUITestSource.sourceID,
                                      title: "Extra Fixture Title \(index)", description: "",
                                      status: "ongoing", year: nil, coverURL: nil, malId: nil)
                    composition.library.toggle(extra)
                    let extraWork = composition.works.mint(from: extra)
                    _ = composition.updates.absorb(workId: extraWork, listing: ListingKey(extra),
                                                   rawNumbers: ["1"], now: earlier)
                    _ = composition.updates.absorb(workId: extraWork, listing: ListingKey(extra),
                                                   rawNumbers: ["1", "2"], now: earlier)
                    extraWorks.append((extraWork, extra))
                }
            }
            if state == .notificationTap, let notified = extraWorks.last {
                // The last Work in the oldest section: off screen until the focus scrolls to it.
                let event = UpdateEvent(workId: notified.work, title: notified.manga.title, newChapterCount: 1,
                                        didExceedCap: false, isAdult: false,
                                        discoveredOrdinals: [ChapterOrdinal.parse("2")!])
                scheduleWhenBackgrounded(event, in: composition)
            }
        case .notificationActions:
            _ = composition.updates.absorb(workId: workId, listing: listing,
                                           rawNumbers: ["1"], now: .now)
            _ = composition.updates.absorb(workId: workId, listing: listing,
                                           rawNumbers: ["1", "2", "3"], now: .now)
            // A real notification for UpdatesUITests.testDeliveredNotificationMarkReadAction,
            // capturing chapter 2 only.
            let event = UpdateEvent(workId: workId, title: manga.title, newChapterCount: 1,
                                    didExceedCap: false, isAdult: false,
                                    discoveredOrdinals: [ChapterOrdinal.parse("2")!])
            scheduleWhenBackgrounded(event, in: composition)
        }
    }

    /// Builds the notification with the production notifier, so its category and payload are
    /// production's. It is scheduled when the app *enters the background*, so it can never
    /// fire while the app is still in front (a fixed delay from launch did, whenever
    /// permission was already granted).
    @MainActor
    private static func scheduleWhenBackgrounded(_ event: UpdateEvent, in composition: AppComposition) {
        Task { @MainActor in
            guard await composition.notifier.authorizationSummary() != .unavailable else { return }
            if await composition.notifier.shouldOfferAuthorization() {
                await composition.notifier.requestAuthorizationIfNeeded()
            }
            let backgrounded = NotificationCenter.default.notifications(
                named: UIApplication.didEnterBackgroundNotification)
            for await _ in backgrounded {
                await composition.notifier.schedule(
                    [event], trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false))
                break
            }
        }
    }
}

struct UpdatesUITestSource: MangaSource {
    static let sourceID = "updates-ui-test"

    let id = sourceID
    let name = "Update Fixture"

    func search(title: String, limit: Int, offset: Int) async throws -> [Manga] { [] }
    func popular(limit: Int, offset: Int) async throws -> [Manga] { [] }
    func mangaDetail(id: String) async throws -> MangaDetail {
        MangaDetail(description: "", authors: [], tags: [], contentRating: nil)
    }
    func chapters(mangaId: String) async throws -> [Chapter] {
        [Chapter(id: "fixture-chapter", number: "1", title: nil)]
    }
    func pageURLs(chapterId: String, preferDataSaver: Bool) async throws -> [URL] { [] }
}

struct NotificationActionsUITestSource: MangaSource {
    static let sourceID = "notification-actions-ui-test"
    let id = sourceID
    let name = "Notification Actions Fixture"
    func search(title: String, limit: Int, offset: Int) async throws -> [Manga] { [] }
    func popular(limit: Int, offset: Int) async throws -> [Manga] { [] }
    func mangaDetail(id: String) async throws -> MangaDetail {
        MangaDetail(description: "", authors: [], tags: [], contentRating: nil)
    }
    func chapters(mangaId: String) async throws -> [Chapter] {
        (1...3).map { Chapter(id: "na-chapter-\($0)", number: "\($0)", title: nil) }
    }
    func pageURLs(chapterId: String, preferDataSaver: Bool) async throws -> [URL] { [] }
}

/// The Updates screen's answering Source: chapters 1–3, titled so a row can be found by name.
struct UpdatesScreenUITestSource: MangaSource {
    static let sourceID = "updates-screen-ui-test"
    let id = sourceID
    let name = "Updates Screen Fixture"
    func search(title: String, limit: Int, offset: Int) async throws -> [Manga] { [] }
    func popular(limit: Int, offset: Int) async throws -> [Manga] { [] }
    func mangaDetail(id: String) async throws -> MangaDetail {
        MangaDetail(description: "", authors: [], tags: [], contentRating: nil)
    }
    func chapters(mangaId: String) async throws -> [Chapter] {
        (1...3).map { Chapter(id: "us-chapter-\($0)", number: "\($0)", title: "Fixture Chapter \($0)") }
    }
    func pageURLs(chapterId: String, preferDataSaver: Bool) async throws -> [URL] { [] }
}

/// A Source that is registered but never answers: the Updates screen's load-failure row and,
/// through a refresh, its recovery notice.
struct FailingUpdatesUITestSource: MangaSource {
    static let sourceID = "failing-updates-ui-test"
    let id = sourceID
    let name = "Failing Fixture"
    func search(title: String, limit: Int, offset: Int) async throws -> [Manga] { [] }
    func popular(limit: Int, offset: Int) async throws -> [Manga] { [] }
    func mangaDetail(id: String) async throws -> MangaDetail { throw URLError(.notConnectedToInternet) }
    func chapters(mangaId: String) async throws -> [Chapter] { throw URLError(.notConnectedToInternet) }
    func pageURLs(chapterId: String, preferDataSaver: Bool) async throws -> [URL] { [] }
}

/// The second source behind the two-listing fixture. It carries **more** chapters than
/// `UpdatesUITestSource` on purpose: the ranking then has a real winner, so a picker that
/// silently ignored the counts would still look right and this fixture would prove nothing.
struct UpdatesUITestAltSource: MangaSource {
    static let sourceID = "updates-ui-test-alt"

    let id = sourceID
    let name = "Alt Fixture"

    func search(title: String, limit: Int, offset: Int) async throws -> [Manga] { [] }
    func popular(limit: Int, offset: Int) async throws -> [Manga] { [] }
    func mangaDetail(id: String) async throws -> MangaDetail {
        MangaDetail(description: "", authors: [], tags: [], contentRating: nil)
    }
    func chapters(mangaId: String) async throws -> [Chapter] {
        (1...3).map { Chapter(id: "alt-chapter-\($0)", number: "\($0)", title: nil) }
    }
    func pageURLs(chapterId: String, preferDataSaver: Bool) async throws -> [URL] { [] }
}
#endif
