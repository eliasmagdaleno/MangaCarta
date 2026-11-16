import XCTest
import UIKit
@testable import MangaCarta

@MainActor
final class ReaderPagePipelineTests: XCTestCase {
    private let manga = Manga(id: "m", sourceId: "fixture", title: "Fixture", description: "",
                              status: "ongoing", year: nil, coverURL: nil, malId: nil)
    private let chapters = [Chapter(id: "c1", number: "1", title: nil, date: nil),
                            Chapter(id: "c2", number: "2", title: nil, date: nil),
                            Chapter(id: "c3", number: "3", title: nil, date: nil)]
    private let urls = [URL(string: "https://fixture.test/0.jpg")!, URL(string: "https://fixture.test/1.jpg")!]
    private let pdfPages = [ReaderPage.pdf(documentURL: URL(fileURLWithPath: "/fixture/doc.pdf"), pageIndex: 0),
                            .pdf(documentURL: URL(fileURLWithPath: "/fixture/doc.pdf"), pageIndex: 1)]

    private class ImageSource: MangaSource {
        let id = "fixture"
        let name = "Fixture"
        var chapterList: [Chapter] = []
        var urls: [URL] = []
        private(set) var urlCalls = 0
        func chapters(mangaId: String) async throws -> [Chapter] { chapterList }
        func pageURLs(chapterId: String, preferDataSaver: Bool) async throws -> [URL] { urlCalls += 1; return urls }
        func search(title: String, limit: Int, offset: Int) async throws -> [Manga] { [] }
        func popular(limit: Int, offset: Int) async throws -> [Manga] { [] }
        func mangaDetail(id: String) async throws -> MangaDetail { throw SourceError.unsupported("detail") }
    }

    private final class VectorSource: ImageSource, VectorPageProviding {
        var references: [ReaderPage] = []
        private(set) var referenceCalls = 0
        func pageReferences(chapterId: String) async throws -> [ReaderPage] { referenceCalls += 1; return references }
    }

    private func model(source: MangaSource, chapter: Chapter? = nil,
                       prefetch: @escaping ([URL], Int, ImageLoadReportTarget?) -> Void = { _, _, _ in }) -> ReaderViewModel {
        ReaderViewModel(manga: manga, chapter: chapter ?? chapters[1], chapters: chapters,
                        initialPosition: ReadingPosition(page: 0), source: source,
                        imageCache: .shared, prefetch: prefetch)
    }

    func testBothPathsLandOnTheSamePage() async {
        let image = ImageSource()
        image.chapterList = chapters
        image.urls = urls
        let vector = VectorSource()
        vector.chapterList = chapters
        vector.references = pdfPages
        let left = model(source: image)
        let right = model(source: vector)

        await left.begin()
        await right.begin()
        XCTAssertEqual(left.pagerTarget, right.pagerTarget)
        XCTAssertEqual(left.pagerTarget.page, 0)
        XCTAssertEqual(left.pages.count, right.pages.count)
        let clampedImage = ReaderViewModel(manga: manga, chapter: chapters[1], chapters: chapters,
                                           initialPosition: ReadingPosition(page: 9), source: image,
                                           imageCache: .shared)
        let clampedVector = ReaderViewModel(manga: manga, chapter: chapters[1], chapters: chapters,
                                            initialPosition: ReadingPosition(page: 9), source: vector,
                                            imageCache: .shared)
        await clampedImage.begin()
        await clampedVector.begin()
        XCTAssertEqual(clampedImage.pagerTarget, clampedVector.pagerTarget)
        XCTAssertEqual(clampedImage.pagerTarget.page, 1)
        await clampedImage.loadNext()
        await clampedVector.loadNext()
        XCTAssertEqual(clampedImage.pagerTarget, clampedVector.pagerTarget)
        XCTAssertEqual(clampedImage.pagerTarget.page, 0)
        XCTAssertEqual(clampedImage.pages.count, clampedVector.pages.count)
        await clampedImage.loadPrevious()
        await clampedVector.loadPrevious()
        XCTAssertEqual(clampedImage.pagerTarget, clampedVector.pagerTarget)
        XCTAssertEqual(clampedImage.pagerTarget.page, 1)
        XCTAssertEqual(clampedImage.pages.count, clampedVector.pages.count)
    }

    func testVectorSourcePublishesItsReferences() async {
        let source = VectorSource()
        source.references = pdfPages
        let vm = model(source: source)
        await vm.begin()
        XCTAssertEqual(vm.pages, pdfPages)
        XCTAssertEqual(source.urlCalls, 0)
        XCTAssertEqual(source.referenceCalls, 1)
    }

    func testPrefetchGetsOnlyImageURLs() async {
        let image = ImageSource()
        image.urls = urls
        var imagePrefetch: [[URL]] = []
        let imageVM = model(source: image) { urls, _, _ in imagePrefetch.append(urls) }
        await imageVM.begin()
        XCTAssertEqual(imagePrefetch, [urls])

        let vector = VectorSource()
        vector.references = pdfPages
        var vectorPrefetchCount = 0
        let vectorVM = model(source: vector) { _, _, _ in vectorPrefetchCount += 1 }
        await vectorVM.begin()
        XCTAssertEqual(vectorPrefetchCount, 0)
    }

    func testEmptyVectorReferencesAreNoPages() async {
        let source = VectorSource()
        source.references = pdfPages
        let vm = model(source: source)
        await vm.begin()
        source.references = []
        await vm.loadNext()
        XCTAssertEqual(vm.errorMessage, "Couldn't load the next chapter. This chapter has no pages to read.")
        XCTAssertEqual(vm.currentChapter.id, chapters[1].id)
        XCTAssertEqual(vm.pages, pdfPages)
    }

    func testLocalSourceIsTheVectorPath() async throws {
        let directory = makeTestDirectory("ReaderPagePipelineTests")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let input = directory.appendingPathComponent("fixture.pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        try renderer.pdfData { context in
            context.beginPage()
            UIColor.red.setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: 100, height: 100))
        }.write(to: input)
        let store = LocalLibraryStore(root: directory.appendingPathComponent("library"), pdfImport: .vector)
        let result = try await store.importArchive(at: input)
        let record: LocalItemRecord
        switch result {
        case .imported(let imported): record = imported
        default:
            XCTFail("Expected imported local PDF")
            return
        }
        let source = LocalSource(store: store)
        let sourceChapters = try await source.chapters(mangaId: record.itemId)
        let chapter = try XCTUnwrap(sourceChapters.first)
        let vm = model(source: source, chapter: chapter)
        await vm.begin()
        XCTAssertEqual(vm.pages, [.pdf(documentURL: directory.appendingPathComponent("library")
            .appendingPathComponent(record.itemId).appendingPathComponent("document.pdf"), pageIndex: 0)])
    }
}
