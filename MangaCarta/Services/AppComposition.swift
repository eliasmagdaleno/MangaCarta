//
//  AppComposition.swift
//  MangaCarta
//
//  The app's object graph, built in one place.
//
//  Extracted out of `MangaCartaApp.init` on 2026-08-08 for one reason: the wiring had no
//  test. Several of the claims this file makes are *by construction* — "one owner of the
//  rate limiter", "one owner of the attempt records" — and a claim by construction is only
//  true while the construction says so. Deleting an argument here breaks none of the 433
//  tests that existed before this file did, because every one of them builds its own graph.
//
//  Storage is injectable so a test can build the real graph against a temp directory and
//  an isolated `UserDefaults`, and then assert on behaviour rather than on shape. Production
//  passes nothing and gets the defaults each store already had.
//

import Foundation
import SwiftUI
import CryptoKit

private struct ExtensionCompositionEnvironmentKey: EnvironmentKey {
    static let defaultValue: AppComposition.ExtensionComposition? = nil
}

private struct ExtensionStorageErrorEnvironmentKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var extensionComposition: AppComposition.ExtensionComposition? {
        get { self[ExtensionCompositionEnvironmentKey.self] }
        set { self[ExtensionCompositionEnvironmentKey.self] = newValue }
    }

    var extensionStorageError: String? {
        get { self[ExtensionStorageErrorEnvironmentKey.self] }
        set { self[ExtensionStorageErrorEnvironmentKey.self] = newValue }
    }
}

/// The app-wide stores, the upgrade queue and the recommendation engine, wired together.
///
/// A `struct` of `let`s rather than an object: it has no behaviour of its own, and the
/// lifetimes that matter are the ones inside it (`@StateObject` in `MangaCartaApp`, and
/// the two actors below, which must outlive a rail build).
@MainActor
struct AppComposition {
    let library: LibraryStore
    let history: HistoryStore
    let taste: TasteProfileStore
    let works: WorkStore
    let engine: RecommendationEngine
    let queue: MetadataUpgradeQueue
    let updates: UpdateStateStore
    let refresh: LibraryRefreshCoordinator
    let notifier: UpdateNotifier
    let scheduler: UpdateScheduler

    /// The one attempt memory. Exposed because it is *shared* — see `init` — and a shared
    /// instance is exactly the kind of thing a test needs to reach to prove the sharing.
    let attempts: UpgradeAttemptMemory

    /// Fulfillment (ADR-0004): which Listing a Work opens with. The count cache is held
    /// here rather than inside the coordinator for the same reason the limiter and the
    /// attempt memory are — "one owner of the counts" is only true by construction if there
    /// is one instance to point at. The preference store is observable and belongs in the
    /// environment, because both Settings and the detail page write to it.
    let listingCounts: ListingCountCache
    let sourcePreferences: SourcePreferenceStore
    let fulfillment: FulfillmentCoordinator

    /// The registry this graph was built with — `SourceRegistry.shared` in production, an
    /// injected one under a UI-test fixture. Exposed because views were reaching for the
    /// singleton directly, which is correct in production and silently wrong whenever the
    /// graph was built with a different registry: source lookups missed, names fell back to
    /// raw ids, and the detail page resolved a source it could not reach.
    let registry: SourceRegistry

    /// Installed Sources (Phase 4), or `nil` when the host's extension storage could not
    /// be opened — the one failure below that has nowhere honest to go, since a Source
    /// without `host.storage` and an eraser without a store are both broken promises.
    /// Views never need this: what they browse is `registry`, which the registrar keeps
    /// current. It is held here so the registrar, the installer and the store live for
    /// the app's lifetime and so a test can drive an install through the real graph.
    let extensions: ExtensionComposition?
    let extensionStorageError: String?

    /// The extension subsystem's four owners, built together because they share one
    /// `SourceLifecycleRegistry`: the installer drives it, the registrar mirrors it.
    @MainActor
    struct ExtensionComposition {
        let repositories: RepositoryStore
        let installer: ExtensionInstaller
        let host: ExtensionHostCapabilityFactory
        let registrar: ExtensionSourceRegistrar
        /// Where S5's acknowledgement sheet plugs in. Declines until then.
        let adultAcknowledgement: AdultInstallAcknowledgementHandle
        let usesBundledTransport: Bool

        /// First-launch install of the bundled WeebCentral package (ADR-0003 Amendment 5),
        /// and on every later launch the refresh that surfaces an app-update's new bundle
        /// `version`. Awaited by `MangaCartaApp` right after composition so the registry is
        /// deterministic by the time any view reads it — an earlier draft fired this from
        /// `init` as an unstructured `Task`, which left `registry.sources` racing.
        ///
        /// A record whose Source the reader *uninstalled* is left alone: the guard is on the
        /// record's existence, not its state, so the app re-offers rather than reinstalls
        /// (A5 part 4). The repository URL is the constant `bundled.invalid` URL; a record holding
        /// any other URL (an earlier draft's `bundled://`) is repointed to it. Returns the installer's sentence when the package could
        /// not be installed — a packaging defect, not a reader-facing state: MangaDex stays
        /// usable and the repositories screen shows the Source as offered.
        @discardableResult
        func installBundledSources() async -> String? {
            guard usesBundledTransport else { return nil }
            let id = BundledRepositories.weebCentralRepositoryID
            do {
                let repository: RepositoryRecord
                if let existing = repositories.repository(id) {
                    repository = existing
                    if existing.indexURL == BundledRepositories.weebCentralURL {
                        _ = try await installer.refresh(id)
                    } else {
                        // A record from before the URL was the constant: refreshing its stored
                        // URL would go to the network and fail on every launch. Repoint it; its
                        // Sources, uninstalled ones included, are kept.
                        _ = try await installer.changeRepositoryURL(id, to: BundledRepositories.weebCentralURL)
                    }
                } else {
                    repository = try await installer.addRepository(at: BundledRepositories.weebCentralURL,
                                                                   repositoryID: id)
                }
                guard repositories.sources(in: id).isEmpty else { return nil }
                _ = try await installer.install(localId: "weebcentral", from: repository.id)
                return nil
            } catch {
                return error.localizedDescription
            }
        }
    }

    /// The AniList pool's two caches (ADR-0011). Held here, not built inside `makeProvider`,
    /// because both are **actors whose state must outlive a rail build**: `AniListPoolStore`
    /// holds the in-flight refresh and the superseded-seeds guard, and a fresh instance per
    /// rebuild would mean no refresh is ever "in flight", the dedupe slice 3 tested would be
    /// silently dead, and the pool would never warm.
    let vocabularyStore: TagVocabularyStore
    let poolStore: AniListPoolStore

    /// The MyAnimeList account, and the progress subsystem behind it. The account store is
    /// observable and belongs in the environment for Settings; the coordinator and the
    /// outbox are not — they publish nothing, and a view that could reach them could only
    /// misuse them (ADR-0010). They are held here so they live for the app's lifetime.
    let account: MALAccountStore
    let malProgress: MALProgressCoordinator
    let malOutbox: MALProgressOutbox

    /// The redirect this app registers with MyAnimeList. One spelling, used by both the
    /// authorization URL and the token exchange; MAL matches it exactly.
    static let malRedirectURI = "mangareader://oauth/mal"

    /// A MAL account isolated from this device's real one. UI tests that assert the
    /// signed-out section need it: they otherwise read the developer's actual Keychain and
    /// preferences, so the assertion passes on fresh CI and fails on any machine that has
    /// ever signed in. Both halves are required — see `MALInMemoryAccountPreferenceStore`.
    static func ephemeralMALAccount() -> (MALCredentialStore, MALAccountPreferenceStore) {
        (MALCredentialStore(dataStore: MALInMemoryCredentialDataStore(),
                            markerStore: MALInMemoryInstallationMarkerStore()),
         MALInMemoryAccountPreferenceStore())
    }

#if DEBUG
    struct RepositorySettingsUITestTransport: RepositoryTransport {
        private static let script = Data("registerEngine('madara', {});".utf8)
        private static let scriptURL = URL(string: "https://fixture.invalid/engine.js")!
        private static let declaration = JSONValue.object([
            "localId": .string("fixture"), "name": .string("Fixture Source"),
            "engine": .string("madara"), "configuration": .object([:]),
            "adult": .string("mixed"),
            "capabilities": .object(["search": .bool(true), "popular": .bool(true),
                                      "detail": .bool(true), "chapters": .bool(true), "pages": .bool(true)]),
            "languages": .object(["mode": .string("fixed"), "values": .array([.string("en")])]),
            "network": .object(["httpOrigins": .array([.string("https://fixture.invalid")])]),
            "hostAPI": .object(["minimum": .string("1.0"), "maximumExclusive": .string("2.0")])
        ])
        private static let index = RepositoryIndex(format: 1, name: "Fixture Repository", bundles: [
            RepositoryBundle(id: "fixture-engine", version: 1, scriptURL: scriptURL,
                             scriptSHA256: SHA256.hash(data: script).map { String(format: "%02x", $0) }.joined(),
                             sources: [RepositorySourceRecord(rawJSON: declaration, localID: "fixture")])
        ])

        func fetchIndex(at url: URL) async throws -> RepositoryIndexFetchOutcome { .index(Self.index) }
        func fetchScript(at url: URL) async throws -> Data { Self.script }
    }

    /// The account states a UI test can put on screen, for the ones a device cannot be
    /// talked into showing on demand. `signedIn` and `reauthorizationRequired` are reached
    /// through `restore()`'s real branches — a cached profile with a credential, and one
    /// without — so what those two verify is the genuine article. `refreshing` and the
    /// account-switch alert are seeded on the store afterwards (see `MALAccountStore`),
    /// because one waits on a token near expiry and the other on a completed sign-in as a
    /// second user; both triggers stay covered by unit tests.
    enum MALUITestAccountState: String {
        case signedIn = "signed-in"
        case reauthorizationRequired = "reauthorization-required"
        case refreshing
        case accountSwitch = "account-switch"
    }

    /// A stand-in account. Deliberately not the developer's — a screenshot of these states
    /// is an artifact that outlives the run, and it should carry nobody's real name.
    static let malUITestProfile = MALUserIdentity(id: 1_000_001,
                                                 name: "UITestReader",
                                                 pictureURL: nil)

    static func seededMALAccount(
        _ state: MALUITestAccountState
    ) -> (MALCredentialStore, MALAccountPreferenceStore) {
        let (credentials, preferences) = ephemeralMALAccount()
        preferences.save(MALAccountPreferences(profile: malUITestProfile,
                                               syncEnabled: true,
                                               automaticallyAddsTitles: false))
        // No credential is exactly what `restore()` reads as "needs reauthorization"; every
        // other state here is a signed-in one and needs one present.
        if state != .reauthorizationRequired {
            try? credentials.save(MALStoredCredential(tokenType: "Bearer",
                                                      accessToken: "uitest-access",
                                                      refreshToken: "uitest-refresh",
                                                      expiresAt: Date().addingTimeInterval(2_678_400),
                                                      malUserID: malUITestProfile.id))
        }
        return (credentials, preferences)
    }
#endif

    /// The injected seams below all default to the production object. They exist so a
    /// test can build **this** graph — not a hand-rolled imitation of it — without a
    /// Keychain, an AniList request, a MyAnimeList search, or a repository fetch.
    init(defaults: UserDefaults = .standard,
         directory: URL = WorkStore.applicationSupportDirectory(),
         malCredentials: MALCredentialStore? = nil,
         malPreferences: MALAccountPreferenceStore? = nil,
         anilist injectedAniList: AniListAPI? = nil,
         malResolver: MALEntityResolver? = nil,
         registry: SourceRegistry? = nil,
         repositoryTransport: (any RepositoryTransport)? = nil) {
        WeebCentralIdentityMigration.run(directory: directory, defaults: defaults)
        let resolvedRegistry = registry ?? .shared
        let resolvedMALResolver = malResolver ?? MALEntityResolver(
            store: .shared,
            source: { resolvedRegistry.externalIdSource })
        // Built first: the three commitment paths below (read, save, feedback) all
        // mint into it, so they must share this one instance (ADR-0007).
        let wk = WorkStore(directory: directory)
        let lib = LibraryStore(defaults: defaults, works: wk)

        // The MyAnimeList stack, built before `HistoryStore` because the history store takes
        // the completion sink at construction. Nothing here touches the network until the
        // user signs in: the account restores from what is already on disk, and the drain
        // only runs once `start()` is called with a signed-in account.
        let outbox = MALProgressOutbox(directory: directory)
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uitest-mal-reset-outbox") {
            // Task 12's stand-in-account checks share the seeded app container. Isolate each
            // initial launch without risking another account's durable queued work.
            try? outbox.clear(userID: Self.malUITestProfile.id)
        }
#endif
        let malConfiguration = MALOAuthConfiguration(
            clientID: (Bundle.main.object(forInfoDictionaryKey: "MALClientID") as? String) ?? "",
            redirectURI: Self.malRedirectURI)
        let malTransport = MALURLSessionTransport()
        let credentials = malCredentials ?? MALCredentialStore(
            dataStore: MALKeychainCredentialDataStore(),
            markerStore: MALUserDefaultsInstallationMarkerStore(defaults: defaults))
        let tokenClient = MALTokenClient(configuration: malConfiguration, transport: malTransport)
        // The refresh spinner in Settings, through the same weak-box shape as `drain` below
        // and for the same reason: the token manager is built before the account store.
        let refreshHandle = MALRefreshHandle()
        let tokens = MALTokenManager(client: tokenClient, store: credentials) { isRefreshing in
            Task { @MainActor in
                guard let account = refreshHandle.account else { return }
                if isRefreshing { account.refreshBegan() } else { account.refreshEnded() }
            }
        }
        // The verb is the client's verified default now — see `MALListUpdateVerb`.
        // Only this client takes the simulated outage; `tokenClient` above keeps the real
        // transport so a `-uitest-mal-offline` run cannot disturb a real account's credentials.
        var progressTransport: any MALHTTPTransport = malTransport
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uitest-mal-offline") {
            progressTransport = MALOfflineTransport()
        }
#endif
        let malClient = MALAuthenticatedClient(tokens: tokens, transport: progressTransport)
        // **Retry now** has to reach a coordinator that does not exist yet, and the
        // coordinator needs the account store — so the button goes through a box that is
        // filled in a few lines below. Weak, so the graph holds no cycle.
        let drain = MALDrainHandle()
        let accountStore = MALAccountStore(
            configuration: malConfiguration,
            presenter: MALWebAuthPresenter(),
            tokenClient: tokenClient,
            credentials: credentials,
            preferences: malPreferences
                ?? MALUserDefaultsAccountPreferenceStore(defaults: defaults),
            outbox: outbox,
            // The identity read for a token that is not in the manager yet — see
            // `MALAuthenticatedClient.currentUser(accessToken:transport:)`.
            fetchIdentity: { token in
                try await MALAuthenticatedClient.currentUser(accessToken: token,
                                                             transport: malTransport)
            },
            retryDelivery: { drain.coordinator?.retryNow() })
        let malProgress = MALProgressCoordinator(
            outbox: outbox,
            client: malClient,
            account: accountStore,
            // The coordinator never resolves anything itself; it only reads what the Work
            // already knows, and waits for the queue's signal otherwise.
            malID: { wk.work($0)?.externalIds.mal })
        drain.coordinator = malProgress
        refreshHandle.account = accountStore

        // The completion sink. Synchronous and network-free by contract — it writes the
        // completed chapter to the outbox and returns.
        let hist = HistoryStore(defaults: defaults, works: wk,
                                chapterCompleted: { [weak malProgress] completion in
                                    malProgress?.chapterCompleted(completion)
                                })
        let ts = TasteProfileStore(defaults: defaults)

        // One update state owner and one refresh pipeline for pull-to-refresh, activation,
        // and background delivery. Keeping the graph here makes accidental private stores
        // in any of those entry points visible to AppCompositionTests.
        let updateState = UpdateStateStore(directory: directory, works: wk)
        let refreshCoordinator = LibraryRefreshCoordinator(
            works: wk, library: lib, history: hist, updates: updateState, registry: resolvedRegistry)
        lib.configureRefreshCoordinator(refreshCoordinator)
        let updateNotifier = UpdateNotifier(updates: updateState, works: wk, library: lib,
                                            defaults: defaults)
        let updateScheduler = UpdateScheduler(
            coordinator: refreshCoordinator,
            notifier: updateNotifier,
            flushStores: {
                updateState.flush()
                wk.flush()
            })

        // One limiter, passed explicitly rather than left to `MetadataUpgradeQueue`'s
        // default argument. ADR-0011 amends ADR-0007's "one owner of the client" to **one
        // owner of the rate limiter**, and that claim is only true by construction if
        // every AniList caller is handed the same instance. The queue and the pool draw on
        // the same 30/min budget.
        let anilist = injectedAniList ?? AniListAPI()
        let limiter = AniListRateLimiter()
        // Hoisted for the same reason as the limiter directly above, and it is the same
        // claim: the queue would otherwise build its own via `memory ?? UpgradeAttemptMemory()`
        // and hold it privately, so "one owner of the attempt records" would be false by
        // construction. Two consumers now read it — the drain, deciding what to skip, and the
        // rail, deciding whether to explain itself (ADR-0015) — and if they saw different
        // records the notice would contradict the drain.
        let memory = UpgradeAttemptMemory(directory: directory)
        // `resolver: nil` leaves `MetadataUpgradeQueue` to build its own, as it always has.
        // A `VerificationSwitches` override sat here from 2026-08-11 to 2026-08-13 to
        // instrument the ADR-0019 runs; it was `#if DEBUG` and nil unless an environment
        // variable was set, and it is gone now that both runs are written up.
        // The metadata → progress edge. The queue gains no progress dependency: it announces
        // a Work whose external ids it just learned, and the coordinator decides what that
        // is worth (Task 9 of the MAL plan).
        let upgrades = MetadataUpgradeQueue(works: wk, anilist: anilist, rateLimiter: limiter,
                                            resolver: resolvedMALResolver, memory: memory,
                                            workMetadataChanged: { [weak malProgress] id in
                                                malProgress?.workMetadataChanged(id)
                                             }, listingParticipates: { [resolvedRegistry] key in
                                                 resolvedRegistry.source(id: key.sourceId)?.participatesInUpdates ?? true
                                            })

        let vocab = TagVocabularyStore(fetch: { try await limiter.run { try await anilist.tagVocabulary() } })
        let pool = AniListPoolStore()

        // The engine pushes, the queue never pulls: pulling would mean the queue
        // building a profile, and building one mints Works (ADR-0009).
        let rec = RecommendationEngine(
            history: hist, library: lib, profileStore: ts, workStore: wk,
            source: { resolvedRegistry.externalIdSource },
            // The third pool (ADR-0011 slice 4). `makeProvider` runs on every rail build, so
            // the provider *struct* is rebuilt each time — that is fine and deliberate, it is
            // a few closures over two actor references. Only the actors need identity, and
            // they are captured from above.
            makeProvider: { @MainActor source in
                // One reverse resolver for both consumers, so the cache-write discipline
                // has a single implementation (ADR-0011). It needs no identity of its own —
                // all its durable state is in `EntityResolutionStore.shared` — so unlike
                // the two actors above, rebuilding it per rail build would also be correct.
                let reverse = MALReverseResolver(source: { resolvedRegistry.externalIdSource })
                return CompositeCandidateProvider(
                    tag: TagCandidateProvider(source: source),
                    mal: MALCandidateProvider(similar: MoreLikeThisProvider(
                        reverse: reverse, source: { resolvedRegistry.externalIdSource })),
                    ani: AniListCandidateProvider(
                        // Hops to the `@MainActor` `WorkStore`; the provider deliberately
                        // is not main-actor-isolated. Same one-way shape as `PriorityPush`.
                        loadWorks: { await MainActor.run { wk.allWorkIds().compactMap { wk.work($0) } } },
                        vocabularyStore: vocab,
                        poolStore: pool,
                        query: { pair, limit in
                            try await limiter.run {
                                try await anilist.media(tags: [pair.a, pair.b], limit: limit)
                            }
                        },
                        resolve: { works in
                            await reverse.resolve(works: works, limit: poolResolveLimit)
                        }))
            },
            pushPriority: { upgrades.setPriority($0) },
            // The one read-only question the recommender may ask the queue's memory
            // (ADR-0015). It cannot start, stop, or steer the drain — `suppresses` only
            // answers "does an unexpired failure already rule this Work out", which is what
            // separates "not tagged yet" from "cannot be tagged". Passed the whole `Work`
            // rather than an id so the `.unmatched(knownTitlesCount:)` comparison stays
            // paired with the Work it was recorded for.
            tagBlocked: { memory.suppresses($0) })

        self.works = wk
        self.library = lib
        self.history = hist
        self.taste = ts
        self.attempts = memory
        self.queue = upgrades
        self.updates = updateState
        self.refresh = refreshCoordinator
        self.notifier = updateNotifier
        self.scheduler = updateScheduler
        self.engine = rec
        self.vocabularyStore = vocab
        self.poolStore = pool
        self.account = accountStore
        self.malProgress = malProgress
        self.malOutbox = outbox
        self.registry = resolvedRegistry
        (self.listingCounts, self.sourcePreferences, self.fulfillment) =
            Self.makeFulfillment(works: wk, registry: self.registry, defaults: defaults)
        let extensionResult = Self.makeExtensions(directory: directory,
                                                   transport: repositoryTransport,
                                                   registry: self.registry)
        self.extensions = extensionResult.composition
        self.extensionStorageError = extensionResult.error
    }

    /// The installed-Source subsystem (Phase 4). Restores every installed Source from
    /// its stored declaration at launch — re-validated, per ADR-0003 Amendment 4 — and
    /// mirrors the result into `registry`, the graph's one. Nothing here touches the
    /// network: the transport is used only by add, refresh, install and update, none of
    /// which run at launch.
    private static func makeExtensions(
        directory: URL,
        transport: (any RepositoryTransport)?,
        registry: SourceRegistry
    ) -> (composition: ExtensionComposition?, error: String?) {
        let host: ExtensionHostCapabilityFactory
        do {
            host = try ExtensionHostCapabilityFactory(directory: directory)
        } catch {
            return (nil, "Installed Sources could not be read. Nothing was removed.")
        }
        let repositories = RepositoryStore(directory: directory)
        let lifecycle = SourceLifecycleRegistry()
        let acknowledgement = AdultInstallAcknowledgementHandle()
        let installer = ExtensionInstaller(
            store: repositories,
            registry: lifecycle,
            transport: transport ?? AppRepositoryTransport(),
            dataEraser: InstalledSourceDataEraser(storage: host.storageRepository),
            acknowledgeAdult: { await acknowledgement.acknowledge($0) })
        installer.restoreInstalledSources()
        let registrar = ExtensionSourceRegistrar(store: repositories, lifecycle: lifecycle,
                                                 host: host, registry: registry)
        return (ExtensionComposition(repositories: repositories, installer: installer, host: host,
                                     registrar: registrar, adultAcknowledgement: acknowledgement,
                                     usesBundledTransport: transport == nil), nil)
    }

    /// Fulfillment's three pieces (ADR-0004). Extracted from `init` only because it had
    /// grown past the body-length limit; the wiring itself is ordinary.
    ///
    /// The count cache takes no `directory`: chapter counts are disposable and belong in
    /// `Caches/` rather than beside the authoritative stores, so it keeps its own default.
    private static func makeFulfillment(
        works: WorkStore,
        registry: SourceRegistry,
        defaults: UserDefaults
    ) -> (ListingCountCache, SourcePreferenceStore, FulfillmentCoordinator) {
        let counts = ListingCountCache()
        let preferences = SourcePreferenceStore(defaults: defaults)
        return (counts, preferences,
                FulfillmentCoordinator(works: works, registry: registry,
                                       counts: counts, preferences: preferences))
    }
}

/// The one indirection in this file: `MALAccountStore`'s **Retry now** needs the
/// coordinator, and the coordinator needs the account store. Weak on purpose — the
/// composition owns the coordinator, and this must not be a second owner.
@MainActor
final class MALDrainHandle {
    weak var coordinator: MALProgressCoordinator?
}

/// The same indirection for the other direction of the same cycle: `MALTokenManager` is
/// built before the account store it notifies about a refresh in flight. Weak for the same
/// reason — the composition owns the store.
final class MALRefreshHandle: @unchecked Sendable {
    @MainActor weak var account: MALAccountStore?
}

/// The one-time acknowledgement for a `mixed` or `adultOnly` install (repository format
/// design §7.1) is a sheet, and the sheet is S5's. Until it is wired here, every adult
/// install is **declined** and nothing is persisted — the fail-closed answer ADR-0003
/// Amendment 2 requires of the classification — rather than waved through.
@MainActor
final class AdultInstallAcknowledgementHandle {
    var present: ((AdultInstallAcknowledgement) async -> Bool)?

    func acknowledge(_ acknowledgement: AdultInstallAcknowledgement) async -> Bool {
        await present?(acknowledgement) ?? false
    }
}
