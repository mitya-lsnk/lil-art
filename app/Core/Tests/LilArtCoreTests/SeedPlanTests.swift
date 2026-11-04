import Testing
@testable import LilArtCore

@Suite struct SeedPlanTests {
  private func counter(from start: UInt32) -> () -> UInt32 {
    var n = start - 1
    return { n += 1; return n }
  }

  @Test func aLockedSeedStepsOnByOneThroughTheBatch() {
    #expect(SeedPlan.seeds(count: 4, locked: true, lockedSeed: 100) == [100, 101, 102, 103])
  }

  @Test func theLockedSeedWrapsAroundInsteadOfTrapping() {
    #expect(SeedPlan.seeds(count: 3, locked: true, lockedSeed: UInt32.max - 1) == [UInt32.max - 1, UInt32.max, 0])
  }

  @Test func unlockedEachPictureGetsItsOwnRandomSeedAndTheFirstIsTheOneDrawnFirst() {
    #expect(SeedPlan.seeds(count: 3, locked: false, lockedSeed: 7, random: counter(from: 50)) == [50, 51, 52])
  }

  @Test func aBatchOfZeroOrLessStillMakesOnePicture() {
    #expect(SeedPlan.seeds(count: 0, locked: true, lockedSeed: 9).count == 1)
    #expect(SeedPlan.seeds(count: -3, locked: false, lockedSeed: 9, random: counter(from: 1)) == [1])
  }

  @Test func aSingleSeedIsTheLockedOneOrARandomOne() {
    #expect(SeedPlan.single(locked: true, lockedSeed: 12) == 12)
    #expect(SeedPlan.single(locked: false, lockedSeed: 12, random: { 77 }) == 77)
  }

  @Test func randomSeedsFitInThirtyOneBits() {
    for _ in 0..<1000 { #expect(SeedPlan.random() <= UInt32(Int32.max)) }
  }
}
