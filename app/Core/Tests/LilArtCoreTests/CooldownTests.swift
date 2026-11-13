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
