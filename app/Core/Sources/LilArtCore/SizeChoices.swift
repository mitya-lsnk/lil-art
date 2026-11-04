import Foundation

enum Aspect: String, Hashable, CaseIterable {
  case square, landscape, portrait, wide, tall

  var label: String {
    switch self {
    case .square: return "1:1"
    case .landscape: return "3:2"
    case .portrait: return "2:3"
    case .wide: return "16:9"
    case .tall: return "9:16"
    }
  }
  /// width / height
  var ratio: Double {
    switch self {
    case .square: return 1
    case .landscape: return 3.0 / 2.0
    case .portrait: return 2.0 / 3.0
    case .wide: return 16.0 / 9.0
    case .tall: return 9.0 / 16.0
    }
  }
  /// The same ratio stood on its end.
  var flipped: Aspect {
    switch self {
    case .square: return .square
    case .landscape: return .portrait
    case .portrait: return .landscape
    case .wide: return .tall
    case .tall: return .wide
    }
  }
  /// Only one of each pair belongs in the menu; the flip button reaches the other.
  static var menu: [Aspect] { [.square, .landscape, .wide] }
}
/// Size is chosen by area, not by typing pixel counts.
enum Megapixels: Double, Hashable, CaseIterable {
  case half = 0.5, one = 1, two = 2, four = 4

  var label: String {
    switch self {
    case .half: return "0.5 мп"
    case .one: return "1 мп"
    case .two: return "2 мп"
    case .four: return "4 мп"
    }
  }

  /// Pixel size for an aspect, snapped to a multiple of 64 as the models expect.
  func size(for aspect: Aspect) -> (Int, Int) {
    let area = rawValue * 1_000_000
    let h = (area / aspect.ratio).squareRoot()
    let w = h * aspect.ratio
    func snap(_ v: Double) -> Int { max(256, Int((v / 64).rounded()) * 64) }
    return (snap(w), snap(h))
  }
}
enum Quality: String, Hashable, CaseIterable {
  case fast, normal, max

  var label: String {
    switch self {
    case .fast: return "быстро"
    case .normal: return "норма"
    case .max: return "максимум"
    }
  }

  /// Quality never invents a step count; it scales the one the model (or the user, for
  /// this model) settled on, so a 4-step turbo model is never asked for 30.
  func steps(from base: Int) -> Int {
    switch self {
    case .fast: return Swift.max(1, Int((Double(base) * 0.5).rounded()))
    case .normal: return base
    case .max: return Swift.min(60, Int((Double(base) * 2).rounded()))
    }
  }
}
