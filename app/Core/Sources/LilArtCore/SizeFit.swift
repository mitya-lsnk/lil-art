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

extension SizeFit {
  /// The size of a picture itself, as near as the engine's steps of 64 allow: 896×1152 stays
  /// 896×1152. A picture bigger than `maxArea` is brought down to it, in the same shape.
  static func nearSource(width: Int, height: Int, maxArea: Double = 4_000_000) -> (width: Int, height: Int)? {
    guard width > 0, height > 0 else { return nil }
    let area = min(maxArea, max(65_536, Double(width) * Double(height)))
    return best(ratio: Double(width) / Double(height), area: area, maxSide: 4096)
  }

  /// Whether a run of this size would crop or stretch a picture of that shape: the two shapes
  /// differ by more than a hair (the steps of 64 alone can make them differ by a few percent).
  static func shapesDiffer(picture: (width: Int, height: Int), run: (width: Int, height: Int)) -> Bool {
    guard picture.width > 0, picture.height > 0, run.width > 0, run.height > 0 else { return false }
    let a = Double(picture.width) / Double(picture.height)
    let b = Double(run.width) / Double(run.height)
    return abs(log(a / b)) > 0.04
  }
}
