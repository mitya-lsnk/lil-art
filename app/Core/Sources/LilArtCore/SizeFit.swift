import Foundation

/// The size a picture's shape asks for within the engine's limits: every side a multiple of 64.
enum SizeFit {
  /// The width and height, in steps of 64 between 256 and `maxSide`, whose shape is nearest to
  /// `ratio` (width / height) and whose pixel count is nearest to `area`. The shape matters
  /// most; the pixel count may drift a little to keep it.
  static func best(ratio: Double, area: Double, maxSide: Int) -> (width: Int, height: Int)? {
    guard ratio > 0, area > 0, ratio.isFinite, area.isFinite else { return nil }
    var best: (w: Int, h: Int, score: Double)?
    for w in stride(from: 256, through: maxSide, by: 64) {
      let h = min(maxSide, max(256, Int((Double(w) / ratio / 64).rounded()) * 64))
      let shapeError = abs(log((Double(w) / Double(h)) / ratio))
      let areaError = abs(log(Double(w * h) / area))
      let score = shapeError * 4 + areaError
      if score < best?.score ?? .infinity { best = (w, h, score) }
    }
    return best.map { ($0.w, $0.h) }
  }
}
