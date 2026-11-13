import Foundation

/// What happens to a clip's frames after the model has made them: nothing, new frames drawn in
/// between so it plays smoother at a higher rate, or new frames in between at the old rate so
/// it lasts longer (and moves slower). The in-between frames are drawn by macOS, not the model.
enum VideoFinish: Equatable, Hashable {
  case asIs
  case smoother(fps: Int)
  case longer(times: Int)

  /// One frame of the finished clip: source frame `index`, or a frame `phase` of the way from
  /// it to the next one (0 < phase < 1).
  struct Step: Equatable {
    var index: Int
    var phase: Double
  }

  struct Plan: Equatable {
    var frames: [Step]
    var fps: Int
  }

  func plan(frames count: Int, fps: Int) -> Plan {
    let same = Plan(frames: (0..<count).map { Step(index: $0, phase: 0) }, fps: fps)
    guard count > 1 else { return same }
    switch self {
    case .asIs:
      return same
    case .longer(let times):
      guard times > 1 else { return same }
      return Plan(frames: Self.spread(count, perInterval: Double(times)), fps: fps)
    case .smoother(let target):
      guard target > fps else { return same }
      return Plan(frames: Self.spread(count, perInterval: Double(target) / Double(fps)), fps: target)
    }
  }

  /// `perInterval` new intervals for each old one, the first and the last frame kept as they are.
  private static func spread(_ count: Int, perInterval: Double) -> [Step] {
    let last = count - 1
    let total = Int((Double(last) * perInterval).rounded())
    return (0...total).map { j in
      let position = Double(j) * Double(last) / Double(total)
      var index = Int(position.rounded(.down))
      var phase = position - Double(index)
      // a hair off a whole frame is that frame; the last frame has nothing after it
      if phase < 1e-6 { phase = 0 }
      if phase > 1 - 1e-6 { index += 1; phase = 0 }
      if index >= last { index = last; phase = 0 }
      return Step(index: index, phase: phase)
    }
  }

  var label: String {
    switch self {
    case .asIs: return "как есть"
    case .smoother(let fps): return "плавнее · \(fps) к/с"
    case .longer(let times): return "длиннее · ×\(times)"
    }
  }

  /// For the settings file.
  var text: String {
    switch self {
    case .asIs: return "asis"
    case .smoother(let fps): return "smooth:\(fps)"
    case .longer(let times): return "long:\(times)"
    }
  }

  init(text: String?) {
    let parts = (text ?? "").split(separator: ":")
    let number = parts.count == 2 ? Int(parts[1]) : nil
    switch (parts.first, number) {
    case ("smooth", let fps?) where fps > 0: self = .smoother(fps: fps)
    case ("long", let times?) where times > 1: self = .longer(times: times)
    default: self = .asIs
    }
  }
}
