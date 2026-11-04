import Foundation

/// The seeds of a batch. With the seed locked, the batch steps it on by one, so four pictures
/// from one locked seed are four different pictures that can all be made again exactly. Unlocked,
/// the first picture takes one random seed and each later one its own.
enum SeedPlan {
  /// A seed the engine accepts everywhere (positive 32-bit).
  static func random() -> UInt32 { UInt32.random(in: 0...UInt32(Int32.max)) }

  static func seeds(
    count: Int, locked: Bool, lockedSeed: UInt32, random next: () -> UInt32 = SeedPlan.random
  ) -> [UInt32] {
    let first = locked ? lockedSeed : next()
    return (0..<max(1, count)).map { index in
      locked ? first &+ UInt32(truncatingIfNeeded: index) : (index == 0 ? first : next())
    }
  }

  /// One seed: the locked one, or a random one.
  static func single(locked: Bool, lockedSeed: UInt32, random next: () -> UInt32 = SeedPlan.random) -> UInt32 {
    locked ? lockedSeed : next()
  }
}
