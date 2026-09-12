//
//  SourceLifecycleRegistryTests.swift
//  MangaCartaTests
//
//  Acceptance criterion 10 ("disable/uninstall/reinstall preserves and reconnects
//  Listings and pins for the same qualified Source id") and the Host API design's §11
//  "Identity lifecycle".
//
//  The adversarial case that matters most: two declarations that share a `localId` but
//  carry different `QualifiedSourceID`s must never be treated as the same Source by any
//  lifecycle transition.
//

import XCTest
@testable import MangaCarta

final class SourceLifecycleRegistryTests: XCTestCase {

    // MARK: - Fixtures

    /// Builds a validated `SourceDeclaration` the same way
    /// `SourceDeclarationValidatorTests` does, so this suite exercises the same
    /// validation path a real install would, rather than hand-rolling a struct that
    /// could drift from what the validator actually produces.
    private func declaration(qualifiedId: QualifiedSourceID,
                             localId: String,
                             name: String = "Example Manga",
                             engine: String = "madara") throws -> SourceDeclaration {
        let dict: [String: Any] = [
            "localId": localId,
            "name": name,
            "engine": engine,
            "configuration": ["baseURL": "https://example.test"],
            "adult": "none",
            "capabilities": [
                "search": true, "popular": true, "newTitles": false,
                "latestUpdates": true, "detail": true, "chapters": true,
                "pages": true, "tagBrowse": false, "webURL": true
            ],
            "languages": ["mode": "fixed", "values": ["en"]],
            "network": [
                "httpOrigins": ["https://example.test"],
                "browserOrigins": ["https://example.test"],
                "assetOrigins": ["https://cdn.example.test"]
            ],
            "presentation": [
                "feeds": [
                    "popular": ["title": "Popular"],
                    "latestUpdates": ["title": "Recently Updated", "badge": "new"]
                ],
                "imagePrefetchConcurrency": 4
            ],
            "hostAPI": ["minimum": "1.0", "maximumExclusive": "2.0"]
        ]
        let data = try JSONSerialization.data(withJSONObject: dict)
        switch SourceDeclarationValidator.validate(json: data, qualifiedId: qualifiedId) {
        case .success(let declaration):
            return declaration
        case .failure(let error):
            XCTFail("fixture declaration failed to validate: \(error)")
            throw error
        }
    }

    // MARK: - Register / disable / uninstall / reinstall, same id

    @MainActor
    func testDisableUnregistersButRemembersTheDeclaration() throws {
        let id = QualifiedSourceID(rawValue: "repoA:site-1")
        let registry = SourceLifecycleRegistry()
        try registry.register(try declaration(qualifiedId: id, localId: "site-1"))

        try registry.disable(id)

        XCTAssertEqual(registry.state(for: id), .disabled)
        XCTAssertFalse(registry.isActive(id))
        XCTAssertNotNil(registry.declaration(for: id), "disable must not forget the declaration")
    }

    @MainActor
    func testUninstallUnregistersButRemembersTheDeclaration() throws {
        let id = QualifiedSourceID(rawValue: "repoA:site-1")
        let registry = SourceLifecycleRegistry()
        try registry.register(try declaration(qualifiedId: id, localId: "site-1"))

        try registry.uninstall(id)

        XCTAssertEqual(registry.state(for: id), .uninstalled)
        XCTAssertFalse(registry.isActive(id))
        XCTAssertNotNil(registry.declaration(for: id), "uninstall must not forget the declaration")
    }

    @MainActor
    func testDisableAndUninstallAreDistinctStates() throws {
        let idA = QualifiedSourceID(rawValue: "repoA:site-1")
        let idB = QualifiedSourceID(rawValue: "repoA:site-2")
        let registry = SourceLifecycleRegistry()
        try registry.register(try declaration(qualifiedId: idA, localId: "site-1"))
        try registry.register(try declaration(qualifiedId: idB, localId: "site-2"))

        try registry.disable(idA)
        try registry.uninstall(idB)

        XCTAssertEqual(registry.state(for: idA), .disabled)
        XCTAssertEqual(registry.state(for: idB), .uninstalled)
        XCTAssertNotEqual(registry.state(for: idA), registry.state(for: idB))
    }

    @MainActor
    func testReinstallAfterDisableReconnectsWithADifferentDeclarationBody() throws {
        let id = QualifiedSourceID(rawValue: "repoA:site-1")
        let registry = SourceLifecycleRegistry()
        try registry.register(try declaration(qualifiedId: id, localId: "site-1", name: "Old Name", engine: "madara"))
        try registry.disable(id)
        XCTAssertFalse(registry.isActive(id))

        // A deliberately different declaration body: name and engine both changed.
        // validateUpdate permits this; only qualifiedId/localId are pinned.
        try registry.reinstall(try declaration(qualifiedId: id, localId: "site-1", name: "New Name", engine: "generic"))

        XCTAssertTrue(registry.isActive(id))
        XCTAssertEqual(registry.state(for: id), .registered)
        XCTAssertEqual(registry.declaration(for: id)?.name, "New Name")
        XCTAssertEqual(registry.declaration(for: id)?.engine, "generic")
    }

    @MainActor
    func testReinstallAfterUninstallReconnects() throws {
        let id = QualifiedSourceID(rawValue: "repoA:site-1")
        let registry = SourceLifecycleRegistry()
        try registry.register(try declaration(qualifiedId: id, localId: "site-1"))
        try registry.uninstall(id)
        XCTAssertFalse(registry.isActive(id))

        try registry.reinstall(try declaration(qualifiedId: id, localId: "site-1", name: "Renamed"))

        XCTAssertTrue(registry.isActive(id))
        XCTAssertEqual(registry.declaration(for: id)?.name, "Renamed")
    }

    @MainActor
    func testFreshReinstallOfNeverSeenIdBehavesLikeRegister() throws {
        let id = QualifiedSourceID(rawValue: "repoA:brand-new")
        let registry = SourceLifecycleRegistry()

        try registry.reinstall(try declaration(qualifiedId: id, localId: "brand-new"))

        XCTAssertTrue(registry.isActive(id))
    }

    @MainActor
    func testRegisterTwiceForSameIdThrowsAlreadyRegistered() throws {
        let id = QualifiedSourceID(rawValue: "repoA:site-1")
        let registry = SourceLifecycleRegistry()
        try registry.register(try declaration(qualifiedId: id, localId: "site-1"))

        XCTAssertThrowsError(try registry.register(try declaration(qualifiedId: id, localId: "site-1"))) { error in
            XCTAssertEqual(error as? SourceLifecycleError, .alreadyRegistered)
        }
    }

    @MainActor
    func testDisableOfUnknownSourceThrows() {
        let registry = SourceLifecycleRegistry()
        XCTAssertThrowsError(try registry.disable(QualifiedSourceID(rawValue: "nope"))) { error in
            XCTAssertEqual(error as? SourceLifecycleError, .unknownSource)
        }
    }

    // MARK: - The adversarial case: shared localId, different QualifiedSourceID

    @MainActor
    func testSharedLocalIdAcrossDifferentRepositoriesNeverReconnects() throws {
        // Two different repositories both happen to use "site-1" as their localId.
        // They must be tracked as two entirely separate Sources.
        let idFromRepoA = QualifiedSourceID(rawValue: "repoA:site-1")
        let idFromRepoB = QualifiedSourceID(rawValue: "repoB:site-1")
        let registry = SourceLifecycleRegistry()

        try registry.register(try declaration(qualifiedId: idFromRepoA, localId: "site-1", name: "Repo A's Site"))
        // Repo B's declaration reuses the same localId string, but was never registered
        // under this registry yet — so repo B installing does not "reconnect" to repo
        // A's entry; it is a brand-new registration under a different id.
        try registry.register(try declaration(qualifiedId: idFromRepoB, localId: "site-1", name: "Repo B's Site"))

        XCTAssertTrue(registry.isActive(idFromRepoA))
        XCTAssertTrue(registry.isActive(idFromRepoB))
        XCTAssertEqual(registry.declaration(for: idFromRepoA)?.name, "Repo A's Site")
        XCTAssertEqual(registry.declaration(for: idFromRepoB)?.name, "Repo B's Site")

        // Disabling repo A's Source must never touch repo B's, despite the identical
        // localId.
        try registry.disable(idFromRepoA)
        XCTAssertFalse(registry.isActive(idFromRepoA))
        XCTAssertTrue(registry.isActive(idFromRepoB), "disabling repo A's Source must not disable repo B's")

        // Uninstalling repo A, then "reinstalling" using repo B's qualifiedId but the
        // same localId must not let repo B's declaration silently take over repo A's
        // entry — they are different entries by construction (different dictionary
        // keys), and this asserts that stays true through the full lifecycle.
        try registry.uninstall(idFromRepoA)
        try registry.reinstall(try declaration(qualifiedId: idFromRepoB, localId: "site-1", name: "Repo B's Site v2"))

        XCTAssertEqual(registry.state(for: idFromRepoA), .uninstalled,
                       "repo A's entry must remain uninstalled — repo B reinstalling under its own id must not resurrect it")
        XCTAssertEqual(registry.declaration(for: idFromRepoA)?.name, "Repo A's Site",
                       "repo A's remembered declaration must be untouched by repo B's activity")
        XCTAssertTrue(registry.isActive(idFromRepoB))
        XCTAssertEqual(registry.declaration(for: idFromRepoB)?.name, "Repo B's Site v2")
    }

    @MainActor
    /// Renamed in review: this does **not** prove a rejection, and the old name
    /// (`testReinstallRejectsAChangedQualifiedIdentityEvenWithSameLocalId`) claimed it did.
    /// A declaration carrying a different `qualifiedId` lands under a different dictionary
    /// key, so it is accepted as a *fresh registration* and `validateUpdate` is never
    /// consulted. What is actually worth asserting — and what this does assert — is that the
    /// original entry is left alone. Mutation-checked: deleting the `validateUpdate` call
    /// from `reinstall` does not fail this test, which is how the misnomer was found.
    func testReinstallUnderADifferentQualifiedIdLeavesTheOriginalEntryAlone() throws {
        let originalId = QualifiedSourceID(rawValue: "repoA:site-1")
        let registry = SourceLifecycleRegistry()
        try registry.register(try declaration(qualifiedId: originalId, localId: "site-1"))
        try registry.disable(originalId)

        // A malformed "reinstall" that changed the qualifiedId is stored as a fresh
        // registration under a *different* key by dictionary construction, so it can
        // never be routed through `reinstall` against `originalId`'s entry — but if a
        // caller mistakenly re-derives entries and calls reinstall with a declaration
        // carrying a different qualifiedId than the one they intend to reconnect,
        // there's no entry sharing that qualifiedId yet, so it becomes a fresh
        // registration rather than a reconnect, never touching `originalId`'s entry.
        let differentId = QualifiedSourceID(rawValue: "repoA:site-1-renamed")
        try registry.reinstall(try declaration(qualifiedId: differentId, localId: "site-1"))

        XCTAssertEqual(registry.state(for: originalId), .disabled,
                       "a declaration under a different qualifiedId must not reconnect the original entry")
        XCTAssertTrue(registry.isActive(differentId))
    }

    @MainActor
    func testReinstallWithChangedLocalIdUnderSameQualifiedIdIsRejected() throws {
        // qualifiedId collisions with a changed localId shouldn't happen from a real
        // installer, but validateUpdate still guards it, and reinstall must not bypass
        // that guard.
        let id = QualifiedSourceID(rawValue: "repoA:site-1")
        let registry = SourceLifecycleRegistry()
        try registry.register(try declaration(qualifiedId: id, localId: "site-1"))
        try registry.disable(id)

        XCTAssertThrowsError(try registry.reinstall(try declaration(qualifiedId: id, localId: "site-1-different"))) { error in
            guard case SourceLifecycleError.declarationInvalid(.localIDChanged(let from, let to)) = error else {
                XCTFail("expected localIDChanged, got \(error)")
                return
            }
            XCTAssertEqual(from, "site-1")
            XCTAssertEqual(to, "site-1-different")
        }
        // The original entry is untouched by the rejected reinstall attempt.
        XCTAssertEqual(registry.state(for: id), .disabled)
        XCTAssertEqual(registry.declaration(for: id)?.localId, "site-1")
    }

    // MARK: - Preservation of Listings and pins, using the app's real pin store

    @MainActor
    func testDisableAndUninstallDoNotTouchThePerWorkPin() throws {
        // SourcePreferenceStore is the app's real per-Work pin store (ListingKey keyed
        // by sourceId String + WorkID). This lifecycle registry has no reference to it
        // and calls nothing on it — that is the preservation guarantee for pins.
        let id = QualifiedSourceID(rawValue: "repoA:site-1")
        let registry = SourceLifecycleRegistry()
        try registry.register(try declaration(qualifiedId: id, localId: "site-1"))

        let defaults = UserDefaults(suiteName: "SourceLifecycleRegistryTests.pins")!
        defaults.removePersistentDomain(forName: "SourceLifecycleRegistryTests.pins")
        let preferences = SourcePreferenceStore(defaults: defaults)
        let workID = WorkID()
        let pin = ListingKey(sourceId: id.rawValue, mangaId: "manga-1")
        preferences.choose(pin, for: workID)

        try registry.disable(id)
        try registry.uninstall(id)

        XCTAssertEqual(preferences.choice(for: workID), pin,
                       "a pin keyed by this Source's qualifiedId must survive disable and uninstall")

        // Reconnect: reinstalling makes the Source active again, and the pin — which
        // was never touched — is exactly the same reference a caller resolving via
        // `id.rawValue` would use again.
        try registry.reinstall(try declaration(qualifiedId: id, localId: "site-1", name: "Reinstalled"))
        XCTAssertTrue(registry.isActive(id))
        XCTAssertEqual(preferences.choice(for: workID), pin)

        defaults.removePersistentDomain(forName: "SourceLifecycleRegistryTests.pins")
    }

    @MainActor
    func testPinnedToOneRepositoryIsUnaffectedByAnotherRepositorySharingTheLocalId() throws {
        let idFromRepoA = QualifiedSourceID(rawValue: "repoA:site-1")
        let idFromRepoB = QualifiedSourceID(rawValue: "repoB:site-1")
        let registry = SourceLifecycleRegistry()
        try registry.register(try declaration(qualifiedId: idFromRepoA, localId: "site-1"))
        try registry.register(try declaration(qualifiedId: idFromRepoB, localId: "site-1"))

        let defaults = UserDefaults(suiteName: "SourceLifecycleRegistryTests.pins2")!
        defaults.removePersistentDomain(forName: "SourceLifecycleRegistryTests.pins2")
        let preferences = SourcePreferenceStore(defaults: defaults)
        let workID = WorkID()
        let pinToRepoA = ListingKey(sourceId: idFromRepoA.rawValue, mangaId: "manga-1")
        preferences.choose(pinToRepoA, for: workID)

        try registry.uninstall(idFromRepoB)
        try registry.reinstall(try declaration(qualifiedId: idFromRepoB, localId: "site-1", name: "Repo B renamed"))

        XCTAssertEqual(preferences.choice(for: workID), pinToRepoA,
                       "repo B's lifecycle activity must never affect a pin naming repo A's qualifiedId")

        defaults.removePersistentDomain(forName: "SourceLifecycleRegistryTests.pins2")
    }

    // MARK: - Preservation of bounded Source storage (S5 seam, faked here)

    private final class FakeQualifiedSourceStorage: QualifiedSourceStorage {
        private var stored: Set<String> = []

        func seed(for id: QualifiedSourceID) { stored.insert(id.rawValue) }
        func hasStorage(for id: QualifiedSourceID) -> Bool { stored.contains(id.rawValue) }
    }

    @MainActor
    func testBoundedStorageSurvivesDisableUninstallAndReinstall() throws {
        let id = QualifiedSourceID(rawValue: "repoA:site-1")
        let registry = SourceLifecycleRegistry()
        try registry.register(try declaration(qualifiedId: id, localId: "site-1"))

        let storage = FakeQualifiedSourceStorage()
        storage.seed(for: id)
        XCTAssertTrue(storage.hasStorage(for: id))

        // `SourceLifecycleRegistry` is never given a reference to `storage` — that is
        // the contract: nothing in this file can clear it. These transitions exercise
        // the full lifecycle while `storage` sits untouched.
        try registry.disable(id)
        XCTAssertTrue(storage.hasStorage(for: id))
        try registry.uninstall(id)
        XCTAssertTrue(storage.hasStorage(for: id))
        try registry.reinstall(try declaration(qualifiedId: id, localId: "site-1", name: "Reinstalled"))
        XCTAssertTrue(registry.isActive(id))
        XCTAssertTrue(storage.hasStorage(for: id), "storage keyed by this qualifiedId must survive the full cycle")
    }

    // MARK: - Reconnection revalidates; it never bypasses adult-classification enforcement

    @MainActor
    /// Renamed in review: the old name
    /// (`testReinstallGoesThroughTheValidatorAndRejectsAMissingAdultClassification`) claimed
    /// a property of `reinstall` that `reinstall` does not have — it never calls
    /// `SourceDeclarationValidator.validate`, and this test never passes the bad declaration
    /// to the registry at all. It exercises the validator directly.
    ///
    /// That gap is narrower than it looks, and deliberately left as is: `SourceDeclaration
    /// .adult` is non-optional, so a declaration missing its classification cannot exist as a
    /// typed value. The only way in is the JSON path asserted below, which rejects it. Since
    /// ADR-0003 Amendment 4 (#161) that is also the only way to obtain a `SourceDeclaration`
    /// at all — its initialiser is private to the validator — so a hand-built one that
    /// bypassed validation is no longer expressible; `ManifestValidationCodeFreeTests` pins
    /// the access modifier.
    func testADeclarationMissingItsAdultClassificationIsRejectedByTheValidator() throws {
        let id = QualifiedSourceID(rawValue: "repoA:site-1")
        let registry = SourceLifecycleRegistry()
        try registry.register(try declaration(qualifiedId: id, localId: "site-1"))
        try registry.disable(id)

        var dict: [String: Any] = [
            "localId": "site-1",
            "name": "Missing Adult Field",
            "engine": "madara",
            "configuration": ["baseURL": "https://example.test"],
            "capabilities": [
                "search": true, "popular": true, "newTitles": false,
                "latestUpdates": true, "detail": true, "chapters": true,
                "pages": true, "tagBrowse": false, "webURL": true
            ],
            "languages": ["mode": "fixed", "values": ["en"]],
            "network": [
                "httpOrigins": ["https://example.test"],
                "browserOrigins": ["https://example.test"],
                "assetOrigins": ["https://cdn.example.test"]
            ],
            "presentation": ["feeds": [:]],
            "hostAPI": ["minimum": "1.0", "maximumExclusive": "2.0"]
        ]
        dict.removeValue(forKey: "adult")
        let data = try JSONSerialization.data(withJSONObject: dict)
        let outcome = SourceDeclarationValidator.validate(json: data, qualifiedId: id)

        // The declaration itself must be rejected at the validator, exactly as it would
        // be for a fresh install — a reconnection path has no separate, laxer route.
        switch outcome {
        case .success:
            XCTFail("a declaration missing 'adult' must never validate, reconnection or not")
        case .failure(let error):
            XCTAssertEqual(error, .missingKey(path: "adult"))
        }

        // And the registry's own entry is untouched by this rejected attempt.
        XCTAssertEqual(registry.state(for: id), .disabled)
    }
}
