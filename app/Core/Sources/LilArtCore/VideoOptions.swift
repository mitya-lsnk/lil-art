import Foundation
#if canImport(LilKitShared)
  // LilStore is internal to the shared file: this package is only ever built to be tested.
  // In the app the shared file lies in the same module, so no import is needed there.
  @testable import LilKitShared
#endif

/// One offered clip size. The engine refuses anything that is not a multiple of 64 on
/// both sides, so every number here is already on that grid — the sizes a video model was
/// trained on (832×480, 960×544) are not, and picking them by hand ends in a refusal.
struct VideoSize: Hashable {
  let width: Int
  let height: Int
  let shape: String

  var label: String { "\(shape) · \(width)×\(height)" }
  var megapixels: Double { Double(width * height) / 1_000_000 }
}

/// The video families the engine can run. Grouped by what the interface needs to know:
/// how fast they play, how long they may be, and which sizes they were trained near.
enum VideoFamily: String, Hashable {
  case wanSmall  // Wan 2.1 1.3B, SkyReels v2 1.3B — the one that fits comfortably
  case wanLarge  // Wan 2.1 14B and both Wan 2.2 A14B experts
  case wan22Small  // Wan 2.2 5B
  case hunyuan
  case ltx
  case svd
  case longcat
  case minimaxH3  // MiniMax H3: the engine's default is 1344×768, 24 frames a second, 124 frames

  static func of(_ rawFamily: String) -> VideoFamily? {
    switch rawFamily {
    case "wan_v2.1_1.3b": return .wanSmall
    case "wan_v2.1_14b": return .wanLarge
    case "wan_v2.2_5b": return .wan22Small
    case "hunyuan_video": return .hunyuan
    case "ltx2", "ltx2.3": return .ltx
    case "svd_i2v": return .svd
    case "longcat_video_avatar_v1.5": return .longcat
    case "minimax_h3": return .minimaxH3
    default: return nil
    }
  }

  static func isVideo(_ rawFamily: String) -> Bool { of(rawFamily) != nil }

  var label: String {
    switch self {
    case .wanSmall: return "Wan 1.3B"
    case .wanLarge: return "Wan 14B"
    case .wan22Small: return "Wan 2.2 5B"
    case .hunyuan: return "Hunyuan Video"
    case .ltx: return "LTX"
    case .svd: return "Stable Video Diffusion"
    case .longcat: return "LongCat"
    case .minimaxH3: return "MiniMax H3"
    }
  }

  /// How fast the finished clip plays. The engine carries the same numbers in the model
  /// specification; these are the fallback when the catalog has not been fetched.
  var fps: Int {
    switch self {
    case .wanSmall, .wanLarge: return 16
    case .wan22Small, .minimaxH3: return 24
    case .hunyuan: return 30
    case .ltx: return 25
    case .longcat: return 25
    // The models make 25 frames meant to be watched slowly; at 30 the clip is over
    // before it starts.
    case .svd: return 7
    }
  }

  /// Longer than this and the model drifts: it was never trained that far.
  var maxFrames: Int {
    switch self {
    case .wanSmall, .wanLarge: return 81
    case .wan22Small: return 121
    case .hunyuan: return 129
    case .ltx: return 121
    case .longcat: return 93
    // The engine accepts up to 362 (17 × 21 + 5), but its own default is 124 and nothing in
    // its source says where quality ends, so the offer stops at the default.
    case .minimaxH3: return 124
    case .svd: return 25
    }
  }

  /// Stable Video Diffusion has no say in the matter.
  var fixedFrames: Int? { self == .svd ? 25 : nil }

  /// Flow-matching models need the noise schedule stretched; this is the usual value.
  var shift: Float {
    switch self {
    case .hunyuan: return 7
    case .wanSmall, .wanLarge, .wan22Small: return 5
    case .minimaxH3: return 12
    case .ltx, .longcat, .svd: return 1
    }
  }

  var sizes: [VideoSize] {
    switch self {
    case .wanSmall:
      return [
        VideoSize(width: 832, height: 448, shape: "широкий"),
        VideoSize(width: 448, height: 832, shape: "вертикальный"),
        VideoSize(width: 576, height: 576, shape: "квадрат"),
      ]
    case .wanLarge, .wan22Small, .ltx:
      return [
        VideoSize(width: 1024, height: 576, shape: "широкий"),
        VideoSize(width: 576, height: 1024, shape: "вертикальный"),
        VideoSize(width: 768, height: 768, shape: "квадрат"),
        VideoSize(width: 832, height: 448, shape: "широкий поменьше"),
      ]
    case .hunyuan:
      return [
        VideoSize(width: 960, height: 512, shape: "широкий"),
        VideoSize(width: 512, height: 960, shape: "вертикальный"),
        VideoSize(width: 768, height: 768, shape: "квадрат"),
      ]
    case .svd:
      return [
        VideoSize(width: 1024, height: 576, shape: "широкий"),
        VideoSize(width: 576, height: 1024, shape: "вертикальный"),
      ]
    case .longcat:
      return [
        VideoSize(width: 832, height: 448, shape: "широкий"),
        VideoSize(width: 448, height: 832, shape: "вертикальный"),
      ]
    case .minimaxH3:
      // Only the first one comes from the engine (its default is 21 × 12 units of 64); the
      // rest are the same area turned, and smaller steps down from it.
      return [
        VideoSize(width: 1344, height: 768, shape: "широкий"),
        VideoSize(width: 768, height: 1344, shape: "вертикальный"),
        VideoSize(width: 768, height: 768, shape: "квадрат"),
        VideoSize(width: 1024, height: 576, shape: "широкий поменьше"),
      ]
    }
  }

  /// The temporal decoder only takes lengths of the form `frameOffset + k × frameStep`; any
  /// other count wastes a whole run (or is refused). Each family compresses time its own way:
  /// Wan, Hunyuan and LongCat by 4 (4k + 1), LTX-2 and 2.3 by 8 (8k + 1), MiniMax H3 in
  /// blocks of 17 after the first 5 (17k + 5).
  var frameStep: Int {
    switch self {
    case .ltx: return 8
    case .minimaxH3: return 17
    default: return 4
    }
  }

  var frameOffset: Int { self == .minimaxH3 ? 5 : 1 }

  /// The shortest legal clip that is still more than a still.
  var minFrames: Int { self == .ltx ? 9 : 5 }

  func frames(forSeconds seconds: Double, fps: Int) -> Int {
    if let fixed = fixedFrames { return fixed }
    let wanted = Int((seconds * Double(fps)).rounded())
    let groups = Int((Double(wanted - frameOffset) / Double(frameStep)).rounded())
    let snapped = frameOffset + groups * frameStep
    // maxFrames itself has to sit on the grid, or the clamp would hand back an illegal length
    let top = frameOffset + max(0, (maxFrames - frameOffset) / frameStep) * frameStep
    return max(minFrames, min(top, snapped))
  }

  func seconds(forFrames frames: Int, fps: Int) -> Double {
    Double(frames) / Double(max(1, fps))
  }

  var maxSeconds: Double { seconds(forFrames: maxFrames, fps: fps) }
}

/// Whether a model was distilled to run in a handful of steps, or is the full one that
/// wants twenty or more.
///
/// Getting this wrong is the single most common way to waste ten minutes: a lightning
/// model at CFG 5 and 30 steps comes out burnt, and a full model at CFG 1 and 4 steps
/// comes out as fog. The app guesses from the name and lets the guess be corrected.
enum SpeedProfile: String, Codable, CaseIterable, Hashable {
  case fast, full

  var label: String {
    switch self {
    case .fast: return "быстрая"
    case .full: return "полная"
    }
  }

  var hint: String {
    switch self {
    case .fast: return "мало шагов, CFG около единицы"
    case .full: return "много шагов, CFG выше"
    }
  }

  /// Words the makers of distilled models actually use. Matched as whole words: "twilight_"
  /// and "moonlight_" end in "light" without being distilled.
  private static let words: Set<String> = [
    "lightning", "light", "lightx2v", "turbo", "distill", "distilled", "causvid", "fusionx",
    "rapid", "lcm", "hyper", "hypersd", "schnell", "dmd", "dmd2",
  ]

  private static let embedded = ["lightspeed", "lightning", "lightx2v", "fusionx", "causvid", "turbo"]

  /// Two words that only mean "distilled" together.
  private static let compounds = ["_self_forcing_", "_step_distill_"]

  /// "4step", "4steps", "8steps": a step count this small is a distilled model's own label.
  private static func isStepCount(_ word: String) -> Bool {
    let digits = word.prefix(while: \.isNumber)
    guard let count = Int(digits), (2...12).contains(count) else { return false }
    let rest = word.dropFirst(digits.count)
    return rest == "step" || rest == "steps"
  }

  static func guess(file: String, name: String) -> SpeedProfile {
    let tokens = (file + " " + name).lowercased()
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    if tokens.contains(where: { words.contains($0) || isStepCount($0) }) { return .fast }
    // marks distinctive enough to count inside a run-together name ("…14BLightspeed…")
    if tokens.contains(where: { token in embedded.contains { token.contains($0) } }) { return .fast }
    // "4 steps" written with a gap: a number straight before the word
    for (index, token) in tokens.enumerated() where token == "step" || token == "steps" {
      if index > 0, isStepCount(tokens[index - 1] + token) { return .fast }
    }
    let joined = "_" + tokens.joined(separator: "_") + "_"
    return compounds.contains(where: { joined.contains($0) }) ? .fast : .full
  }

  func steps(for family: VideoFamily?) -> Int {
    switch self {
    case .fast: return family == .ltx ? 8 : 6
    // MiniMax H3 ships with 50 steps at CFG 1 as its own default; CFG 5 would burn it
    case .full: return family == .hunyuan ? 30 : (family == .minimaxH3 ? 50 : 20)
    }
  }

  var stepRange: ClosedRange<Double> {
    switch self {
    case .fast: return 2...16
    case .full: return 8...50
    }
  }

  func cfg(for family: VideoFamily?) -> Float {
    switch self {
    case .fast: return 1
    case .full: return family == .hunyuan ? 6 : (family == .minimaxH3 ? 1 : 5)
    }
  }
}

/// The user's own verdict on a model, when the guess was wrong. Kept per file, because
/// it belongs to the model rather than to the session.
enum SpeedPrefs {
  private static let key = "model.speed"

  static func stored(_ model: String) -> SpeedProfile? {
    guard let all = LilStore.standard.dictionary(forKey: key) as? [String: String],
      let raw = all[model]
    else { return nil }
    return SpeedProfile(rawValue: raw)
  }

  static func save(_ profile: SpeedProfile?, for model: String) {
    var all = (LilStore.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
    all[model] = profile?.rawValue
    LilStore.standard.set(all, forKey: key)
  }

  static func profile(file: String, name: String) -> SpeedProfile {
    stored(file) ?? SpeedProfile.guess(file: file, name: name)
  }
}

/// Settings a model's maker wrote into its catalog description ("Start with 16 steps, Text
/// Guidance 1 and Shift 16"). The engine's own recommendation does not carry all of them: for
/// FLUX.3 klein it leaves shift at 1, and the pictures come out with artefacts.
struct NoteSettings {
  var steps: Int?
  var cfg: Double?
  var shift: Double?

  init(_ note: String) {
    func number(_ pattern: String) -> Double? {
      guard let range = note.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else {
        return nil
      }
      let found = note[range].range(of: #"\d+(\.\d+)?"#, options: .regularExpression)
      return found.flatMap { Double(note[range][$0]) }
    }
    steps = number(#"\d+\s+steps"#).map { Int($0) }
    cfg = number(#"(text guidance|guidance scale|cfg)\s*(of\s*)?\d+(\.\d+)?"#)
    shift = number(#"shift\s*(of\s*)?\d+(\.\d+)?"#)
  }
}

/// Models the person marked as animating a picture (or not), against the app's guess.
enum ImageInputPrefs {
  private static let key = "model.takesImage"

  static func stored(_ model: String) -> Bool? {
    (LilStore.standard.dictionary(forKey: key) as? [String: Bool])?[model]
  }

  static func save(_ value: Bool?, for model: String) {
    var all = (LilStore.standard.dictionary(forKey: key) as? [String: Bool]) ?? [:]
    all[model] = value
    LilStore.standard.set(all, forKey: key)
  }
}

/// The second expert chosen for each high-noise model, and where it takes over.
enum RefinerPrefs {
  private static let key = "model.refiner"

  static func stored(_ model: String) -> (file: String, start: Double)? {
    guard let all = LilStore.standard.dictionary(forKey: key) as? [String: [String: Any]],
      let mine = all[model], let file = mine["file"] as? String
    else { return nil }
    return (file, (mine["start"] as? Double) ?? 0.1)
  }

  static func save(_ file: String, start: Double, for model: String) {
    var all = (LilStore.standard.dictionary(forKey: key) as? [String: [String: Any]]) ?? [:]
    all[model] = ["file": file, "start": start]
    LilStore.standard.set(all, forKey: key)
  }
}
