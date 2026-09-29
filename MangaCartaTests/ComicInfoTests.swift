import Foundation
import Testing
@testable import MangaCarta

@Suite("ComicInfoParserTests")
struct ComicInfoParserTests {
    @Test func parsesMetadataAndIgnoresManga() {
        let xml = """
        <ComicInfo><Series>  Series Name </Series><Title>Issue title</Title><Number> 2 </Number><Volume>1</Volume>
        <Summary> Summary </Summary><Writer>A, B, ,</Writer><Genre>Action,  Fantasy,</Genre>
        <Manga><ReadingDirection>RTL</ReadingDirection><Title>wrong</Title></Manga>
        <Pages><Page Image="0" Type="Story"/><Page Image="3" Type="FrontCover"/></Pages></ComicInfo>
        """
        let info = ComicInfo.parse(Data(xml.utf8))
        #expect(info == ComicInfo(series: "Series Name", title: "Issue title", number: "2", volume: "1",
                                  summary: "Summary", writer: "A, B, ,", genres: ["Action", "Fantasy"], frontCoverPageIndex: 3))
    }

    @Test func malformedOrWrongRootReturnsNil() {
        #expect(ComicInfo.parse(Data("<ComicInfo>".utf8)) == nil)
        #expect(ComicInfo.parse(Data("<Other/>".utf8)) == nil)
    }

    @Test func parsesPartialMetadata() {
        let info = ComicInfo.parse(Data("<ComicInfo><Series>Series</Series><Summary>Summary</Summary></ComicInfo>".utf8))
        #expect(info?.series == "Series")
        #expect(info?.summary == "Summary")
        #expect(info?.title == nil)
        #expect(info?.genres.isEmpty == true)
    }
}
