//
//  SourcePreferenceStoreTests.swift
//  MangaCartaTests
//
//  Two preferences that compose: a primary source the reader picks once, and a
//  per-Work choice that overrides it when they deliberately switch on a title.
//

import Combine
import XCTest
@testable import MangaCarta

@MainActor
final class SourcePreferenceStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var works: WorkStore!
    private var workID: WorkID!

    override func setUp() async throws {
        defaults = makeTestDefaults("SourcePreferenceStoreTests")
        works = WorkStore(directory: makeTestDirectory("SourcePreferenceStoreTests"))
        workID = mint("work")
    }

    override func tearDown() async throws {
    }

    private func mint(_ id: String) -> WorkID {
        works.mint(from: Manga(id: id, sourceId: "src", title: id, description: "",
                               status: "ongoing", year: nil, coverURL: nil, malId: nil))
    }

    private func makeStore() -> SourcePreferenceStore {
        SourcePreferenceStore(defaults: defaults, works: works)
    }

    private let weebCentral = ListingKey(sourceId: "weebcentral", mangaId: "one-piece")

    /// Until the reader says otherwise there is no preference — and `nil` is the
    /// answer, not a guessed source. The router already has a sensible default and
    /// inventing one here would put the same decision in two places.
    func testNoPrimarySourceUntilOneIsChosen() {
        let store = makeStore()

        XCTAssertNil(store.primarySourceId)
    }

    func testChosenPrimarySourceIsRemembered() {
        let store = makeStore()

        store.primarySourceId = "weebcentral"

        XCTAssertEqual(makeStore().primarySourceId,
                       "weebcentral")
    }

    /// The per-title override. Deliberately switching source on one manga is a
    /// statement about that manga, and it has to outlive the visit or it reads as
    /// the app forgetting.
    func testAPerWorkChoiceSurvivesARelaunch() {
        let store = makeStore()

        store.choose(weebCentral, for: workID)

        XCTAssertEqual(makeStore().choice(for: workID),
                       weebCentral)
    }

    /// Choosing on one Work says nothing about another. The global preference is
    /// the place for "always prefer this source"; a per-title pick is narrower on
    /// purpose.
    func testAPerWorkChoiceDoesNotLeakToOtherWorks() {
        let store = makeStore()

        store.choose(weebCentral, for: workID)

        XCTAssertNil(store.choice(for: mint("other")))
    }

    /// A reader who switches back to the ranked pick is telling us to stop
    /// overriding, not to pin the ranking's current answer — those differ the
    /// moment a better Listing appears.
    func testClearingAChoiceReturnsTheWorkToTheRanking() {
        let store = makeStore()
        store.choose(weebCentral, for: workID)

        store.clearChoice(for: workID)

        XCTAssertNil(store.choice(for: workID))
    }

    // MARK: - Merges (#310)

    private let mangaDex = ListingKey(sourceId: "mangadex", mangaId: "op")

    /// A merge moves the pinned Listing to the survivor, so the pin has to follow it —
    /// the detail page and the router only ever ask with the survivor's id.
    func testAPinFollowsItsWorkIntoAMerge() {
        let store = makeStore()
        let survivor = mint("survivor")
        store.choose(weebCentral, for: workID)

        works.merge(workID, into: survivor)

        XCTAssertEqual(store.choice(for: survivor), weebCentral)
        XCTAssertEqual(makeStore().choice(for: survivor), weebCentral)
    }

    /// The survivor's own pin is the more deliberate statement about the merged title.
    func testTheSurvivorsOwnPinWinsAMerge() {
        let store = makeStore()
        let survivor = mint("survivor")
        store.choose(weebCentral, for: workID)
        store.choose(mangaDex, for: survivor)

        works.merge(workID, into: survivor)

        XCTAssertEqual(store.choice(for: survivor), mangaDex)
        XCTAssertEqual(store.choice(for: workID), mangaDex)

        // Any later write re-keys the stored map; the same rule has to hold there.
        store.choose(weebCentral, for: mint("other"))
        XCTAssertEqual(makeStore().choice(for: survivor), mangaDex)
    }

    /// Clearing on the survivor clears what it inherited, and stays cleared after a
    /// relaunch — an inherited pin under the old id must not come back.
    func testClearingAfterAMergeRemovesTheInheritedPin() {
        let store = makeStore()
        let survivor = mint("survivor")
        store.choose(weebCentral, for: workID)
        works.merge(workID, into: survivor)

        store.clearChoice(for: survivor)

        XCTAssertNil(store.choice(for: survivor))
        XCTAssertNil(makeStore().choice(for: survivor))
    }

    /// Views read pins in `body`; publishing from a read is a SwiftUI runtime error.
    func testReadingAMergedPinDoesNotPublish() {
        let store = makeStore()
        let survivor = mint("survivor")
        store.choose(weebCentral, for: workID)
        works.merge(workID, into: survivor)
        var published = 0
        let cancellable = store.objectWillChange.sink { published += 1 }

        _ = store.choice(for: survivor)

        XCTAssertEqual(published, 0)
        cancellable.cancel()
    }
}
