import CoreGraphics
import Foundation
import Testing
@testable import LilArtCore

private func region(_ number: Int, _ text: String, box: CGRect, source: CGRect? = nil) -> Region {
  Region(number: number, box: box, source: source ?? box, text: text)
}

@Suite struct RegionLayoutTests {
  @Test func onlyFlux3KleinFamiliesTakeBoxes() {
    #expect(RegionLayout.supports(family: "flux3_5b"))
    #expect(!RegionLayout.supports(family: "flux2"))
    #expect(!RegionLayout.supports(family: "qwen_image_2.1"))
    #expect(!RegionLayout.supports(family: ""))
  }

  /// The model was taught [y_min, x_min, y_max, x_max] on 0…1000; x first would put things in the wrong place.
  @Test func boxesAreWrittenYFirstOnAThousandScale() throws {
    let prompt = RegionLayout.prompt(
      caption: "A cat <region_1> next to a dog <region_2>.",
      regions: [
        region(1, "кот", box: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)),
        region(2, "dog", box: CGRect(x: 0.5, y: 0.0, width: 0.5, height: 1.0)),
      ], edit: false)
    #expect(prompt.hasPrefix("A cat <region_1> next to a dog <region_2>. ["))
    let json = try #require(prompt.firstIndex(of: "[")).self
    let items = try #require(
      try JSONSerialization.jsonObject(with: Data(prompt[json...].utf8)) as? [[String: Any]])
    #expect(items[0]["id"] as? String == "region_1")
    #expect(items[0]["bbox"] as? [Int] == [200, 100, 600, 400])
    #expect(items[1]["bbox"] as? [Int] == [0, 500, 1000, 1000])
    #expect(items[1]["desc"] as? String == "dog")
  }

  @Test func theEnglishMadeFromTheCurrentTextIsWhatTheModelReads() throws {
    var cat = region(1, "кот", box: CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
    cat.english = "a cat"
    cat.englishSource = "кот"
    #expect(cat.modelText == "a cat")
    // the Russian was edited after the translation: the stale English must not be sent
    cat.text = "рыжий кот"
    #expect(cat.modelText == "рыжий кот")
  }

  @Test func aBoxTheCaptionDoesNotNameIsNamedAtTheEnd() {
    let prompt = RegionLayout.prompt(
      caption: "A street", regions: [region(1, "bicycle", box: CGRect(x: 0, y: 0, width: 0.5, height: 0.5))],
      edit: false)
    #expect(prompt.hasPrefix("A street. With <region_1>. ["))
  }

  @Test func boxesWithoutADescriptionAreLeftOut() {
    let prompt = RegionLayout.prompt(
      caption: "A street <region_1>", regions: [region(1, "  ", box: CGRect(x: 0, y: 0, width: 1, height: 1))],
      edit: false)
    #expect(prompt == "A street <region_1>")
  }

  @Test func anEditNamesTheReferencePictureAndGivesWhereFromAndWhereTo() throws {
    var mug = region(1, "mug", box: CGRect(x: 0.2, y: 0.4, width: 0.2, height: 0.3),
                     source: CGRect(x: 0.6, y: 0.4, width: 0.2, height: 0.3))
    mug.english = ""
    let prompt = RegionLayout.prompt(caption: "move the mug <region_1> left", regions: [mug], edit: true)
    #expect(prompt.hasPrefix("In <ref_image_0>, move the mug <region_1> left ["))
    let start = try #require(prompt.firstIndex(of: "["))
    let items = try #require(
      try JSONSerialization.jsonObject(with: Data(prompt[start...].utf8)) as? [[String: Any]])
    #expect(items[0]["from"] as? String == "ref_image_0")
    #expect(items[0]["src_bbox"] as? [Int] == [400, 600, 700, 800])
    #expect(items[0]["tgt_bbox"] as? [Int] == [400, 200, 700, 400])
    #expect(mug.moved)
  }

  @Test func quotesAndNewlinesInADescriptionDoNotBreakTheJSON() throws {
    let prompt = RegionLayout.prompt(
      caption: "x <region_1>", regions: [region(1, "a \"big\" sign\nof wood", box: CGRect(x: 0, y: 0, width: 1, height: 1))],
      edit: false)
    let start = try #require(prompt.firstIndex(of: "["))
    let items = try #require(
      try JSONSerialization.jsonObject(with: Data(prompt[start...].utf8)) as? [[String: Any]])
    #expect(items[0]["desc"] as? String == "a \"big\" sign\nof wood")
  }

  @Test func boxesOutsideThePictureAreClamped() throws {
    let prompt = RegionLayout.prompt(
      caption: "x <region_1>", regions: [region(1, "a", box: CGRect(x: -0.2, y: 0.5, width: 1.6, height: 0.9))],
      edit: false)
    #expect(prompt.contains("[500, 0, 1000, 1000]"))
  }
}
