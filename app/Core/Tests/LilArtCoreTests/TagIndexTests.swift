import Testing
@testable import LilArtCore

@Suite struct TagIndexTests {
  let csv = """
    long_hair,0,5000,"longhair,hair_long"
    short_hair,0,9000,
    shirt,0,7000,
    ^_^,0,300,
    "quoted,0,1,
    bad line
    sh,0,notanumber
    """

  @Test func aTagIsFoundByItsStartByALaterWordAndByAnAlias() {
    let index = TagIndex.parse(csv)
    #expect(index.search("long", limit: 10).map(\.name) == ["long_hair"])
    #expect(index.search("hair", limit: 10).map(\.name) == ["short_hair", "long_hair"])
    #expect(index.search("longhair", limit: 10).map(\.name) == ["long_hair"])
  }

  @Test func resultsAreRankedByPopularityAndCutAtTheLimit() {
    let index = TagIndex.parse(csv)
    #expect(index.search("sh", limit: 10).map(\.name) == ["short_hair", "shirt"])
    #expect(index.search("sh", limit: 1).map(\.name) == ["short_hair"])
  }

  @Test func spacesStandForUnderscoresAndShortQueriesFindNothing() {
    let index = TagIndex.parse(csv)
    #expect(index.search("short hair", limit: 5).map(\.name) == ["short_hair"])
    #expect(index.search("s", limit: 5).isEmpty)
  }

  @Test func brokenLinesAreSkipped() {
    #expect(TagIndex.parse(csv).entries.count == 4)
  }

  @Test func displayTurnsUnderscoresIntoSpacesExceptInEmoticons() {
    #expect(TagIndex.display("long_hair") == "long hair")
    #expect(TagIndex.display("^_^") == "^_^")
  }

  @Test func popularityIsShortened() {
    #expect(TagIndex.short(999) == "999")
    #expect(TagIndex.short(1500) == "1k")
    #expect(TagIndex.short(2_500_000) == "2.5M")
  }
}
