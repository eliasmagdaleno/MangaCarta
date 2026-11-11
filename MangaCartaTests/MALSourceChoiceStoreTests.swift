import Foundation
import Testing
@testable import MangaCarta

@Suite("MALSourceChoiceStoreTests")
struct MALSourceChoiceStoreTests {
    @Test func testConfirmedChoiceSurvivesReload() async {
        let directory = TestDirectory(#function)
        defer { directory.remove() }
        let value = Manga(id: "m", sourceId: "source", title: "Title", description: "",
                          status: "unknown", year: nil, coverURL: nil, malId: nil)
        let date = Date(timeIntervalSince1970: 42)
        await MALSourceChoiceStore(directory: directory.url).confirm(malId: 7, sourceId: "source",
                                                                      manga: value, title: "MAL", confirmedAt: date)
        let reloaded = MALSourceChoiceStore(directory: directory.url)
        let choice = await reloaded.choice(for: 7)
        #expect(choice?.manga == value)
        #expect(choice?.confirmedAt == date)
    }

    @Test func testConfirmReplacesPreviousChoiceForSameMALId() async {
        let directory = TestDirectory(#function)
        defer { directory.remove() }
        let first = Manga(id: "one", sourceId: "a", title: "One", description: "",
                          status: "unknown", year: nil, coverURL: nil, malId: nil)
        let second = Manga(id: "two", sourceId: "b", title: "Two", description: "",
                           status: "unknown", year: nil, coverURL: nil, malId: nil)
        let store = MALSourceChoiceStore(directory: directory.url)
        await store.confirm(malId: 7, sourceId: "a", manga: first, title: "First")
        await store.confirm(malId: 7, sourceId: "b", manga: second, title: "Second")
        let choice = await store.choice(for: 7)
        #expect(choice?.sourceId == "b")
        #expect(choice?.manga == second)
    }
}
