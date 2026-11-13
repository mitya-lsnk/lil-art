import Testing
@testable import LilArtCore

@Suite struct CooldownTests {
  @Test func aHotChipWaitsBeforeTheNextJob() {
    #expect(Cooldown.shouldWait(chip: 88, limit: 70, waited: 0))
  }

  @Test func aCoolChipGoesStraightOn() {
    #expect(!Cooldown.shouldWait(chip: 65, limit: 70, waited: 0))
    #expect(!Cooldown.shouldWait(chip: 70, limit: 70, waited: 0))
  }

  @Test func switchedOffItNeverWaits() {
    #expect(!Cooldown.shouldWait(chip: 99, limit: 0, waited: 0))
  }

  /// A chip that will not cool (a hot room) must not hold the queue for ever.
  @Test func theWaitHasAnEnd() {
    #expect(Cooldown.shouldWait(chip: 88, limit: 70, waited: Cooldown.longestWait - 1))
    #expect(!Cooldown.shouldWait(chip: 88, limit: 70, waited: Cooldown.longestWait))
  }

  @Test func withNoSensorThereIsNothingToWaitFor() {
    #expect(!Cooldown.shouldWait(chip: nil, limit: 70, waited: 0))
  }
}

@Suite struct VideoUpscaleTests {
  @Test func theChoiceIsOneOfTheFactorsMacOSTakes() {
    #expect(VideoUpscale(text: "1.5") == .x1_5)
    #expect(VideoUpscale(text: "2") == .x2)
    #expect(VideoUpscale(text: nil) == .none)
    #expect(VideoUpscale(text: "7") == .none)
    for choice in VideoUpscale.allCases { #expect(VideoUpscale(text: choice.text) == choice) }
  }

  @Test func eachChoiceSaysWhatSizeComesOut() {
    #expect(VideoUpscale.none.size(width: 832, height: 480) == VideoSizePair(width: 832, height: 480))
    #expect(VideoUpscale.x2.size(width: 832, height: 480) == VideoSizePair(width: 1664, height: 960))
    #expect(VideoUpscale.x1_5.size(width: 832, height: 480) == VideoSizePair(width: 1248, height: 720))
  }

  @Test func theLabelsAreShort() {
    #expect(VideoUpscale.none.label == "размер как есть")
    #expect(VideoUpscale.x2.label == "увеличить ×2")
    #expect(VideoUpscale.x1_5.label == "увеличить ×1.5")
  }
}
