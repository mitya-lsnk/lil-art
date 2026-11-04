import Testing
@testable import LilArtCore

@Suite struct SizeChoicesTests {
  @Test func sizesAreMultiplesOf64WithTheAskedShapeAndArea() {
    #expect(Megapixels.one.size(for: .square) == (1024, 1024))
    #expect(Megapixels.one.size(for: .wide) == (1344, 768))
    #expect(Megapixels.one.size(for: .tall) == (768, 1344))
    #expect(Megapixels.four.size(for: .square) == (1984, 1984))
    #expect(Megapixels.half.size(for: .landscape) == (896, 576))
    for mp in Megapixels.allCases {
      for aspect in Aspect.allCases {
        let (w, h) = mp.size(for: aspect)
        #expect(w % 64 == 0 && h % 64 == 0 && w >= 256 && h >= 256, "\(mp) \(aspect)")
      }
    }
  }

  @Test func flippingAnAspectSwapsWidthAndHeight() {
    for aspect in Aspect.allCases {
      #expect(aspect.flipped.flipped == aspect)
      let (w, h) = Megapixels.two.size(for: aspect)
      let (fw, fh) = Megapixels.two.size(for: aspect.flipped)
      #expect(abs(w - fh) <= 64 && abs(h - fw) <= 64)
    }
    #expect(Aspect.menu == [.square, .landscape, .wide])
  }

  /// Quality scales the step count the model settled on; it never invents one.
  @Test func qualityScalesTheModelsOwnSteps() {
    #expect(Quality.fast.steps(from: 8) == 4)
    #expect(Quality.fast.steps(from: 1) == 1)
    #expect(Quality.normal.steps(from: 8) == 8)
    #expect(Quality.max.steps(from: 8) == 16)
    #expect(Quality.max.steps(from: 40) == 60)
    #expect(Quality.fast.steps(from: 4) == 2)
  }

  @Test func eachChoiceHasALabel() {
    #expect(Aspect.allCases.map(\.label) == ["1:1", "3:2", "2:3", "16:9", "9:16"])
    #expect(Megapixels.half.label == "0.5 мп")
    #expect(Quality.max.label == "максимум")
  }
}

@Suite struct SizeFitTests {
  @Test func aWidePictureGetsAWideSizeNearTheWantedArea() throws {
    let fit = try #require(SizeFit.best(ratio: 16.0 / 7.0, area: 1_000_000, maxSide: 4096))
    #expect(fit.width % 64 == 0 && fit.height % 64 == 0)
    let shape = Double(fit.width) / Double(fit.height)
    #expect(abs(shape / (16.0 / 7.0) - 1) < 0.08)
    #expect(abs(Double(fit.width * fit.height) / 1_000_000 - 1) < 0.25)
  }

  @Test func aSquarePictureGetsASquare() {
    let fit = SizeFit.best(ratio: 1, area: 1_048_576, maxSide: 4096)
    #expect(fit?.width == 1024 && fit?.height == 1024)
  }

  @Test func theLimitOfTheSideIsRespected() throws {
    let fit = try #require(SizeFit.best(ratio: 5, area: 8_000_000, maxSide: 2048))
    #expect(fit.width <= 2048 && fit.height >= 256)
    let tall = try #require(SizeFit.best(ratio: 0.05, area: 8_000_000, maxSide: 2048))
    #expect(tall.height <= 2048 && tall.width >= 256)
  }

  @Test func nonsenseGivesNothing() {
    #expect(SizeFit.best(ratio: 0, area: 1, maxSide: 4096) == nil)
    #expect(SizeFit.best(ratio: .nan, area: 1, maxSide: 4096) == nil)
    #expect(SizeFit.best(ratio: 1, area: -5, maxSide: 4096) == nil)
  }
}
