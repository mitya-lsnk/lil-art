import Foundation

#if canImport(LilKitShared)
  @testable import LilKitShared
#endif

/// How long one run took, and nothing else: no prompt, no seed, no picture. The person agreed
/// to these numbers being kept so the models page can say how fast each model is.
struct RunTime: Codable, Equatable {
  var width: Int
  var height: Int
  var steps: Int
  /// 0 for a picture.
  var frames: Int
  var seconds: Double
}

/// The last runs of every model, in `runs.times`, and what they add up to.
enum RunTimes {
  static let key = "runs.times"
  static let limit = 30

  static func all(in store: LilStore) -> [String: [RunTime]] {
    guard let data = store.data(forKey: key),
      let decoded = try? JSONDecoder().decode([String: [RunTime]].self, from: data)
    else { return [:] }
    return decoded
  }

  static func add(_ run: RunTime, for model: String, in store: LilStore) {
    guard run.seconds > 0, !model.isEmpty else { return }
    var everything = all(in: store)
    var list = everything[model] ?? []
    list.append(run)
    if list.count > limit { list.removeFirst(list.count - limit) }
    everything[model] = list
    store.set(try? JSONEncoder().encode(everything), forKey: key)
  }

  static func clear(in store: LilStore) { store.removeObject(forKey: key) }

  struct Summary: Equatable {
    var seconds: Double
    var width: Int
    var height: Int
    var steps: Int
    var frames: Int
    var count: Int

    var label: String {
      var parts = ["≈ " + RunTimes.duration(seconds), "\(width)×\(height)"]
      if frames > 0 { parts.append(RunTimes.plural(frames, "кадр", "кадра", "кадров")) }
      parts.append(RunTimes.steps(steps))
      parts.append("запусков: \(count)")
      return parts.joined(separator: " · ")
    }
  }

  /// The middle time of the runs at the size, steps and length used most often.
  static func summary(of model: String, in store: LilStore) -> Summary? {
    guard let list = all(in: store)[model], !list.isEmpty else { return nil }
    struct Shape: Hashable { let w, h, steps, frames: Int }
    let groups = Dictionary(grouping: list) { Shape(w: $0.width, h: $0.height, steps: $0.steps, frames: $0.frames) }
    // the most used; a tie goes to the shape run last
    let lastIndex: (Shape) -> Int = { shape in
      list.lastIndex { Shape(w: $0.width, h: $0.height, steps: $0.steps, frames: $0.frames) == shape } ?? 0
    }
    guard let best = groups.max(by: { a, b in
      a.value.count != b.value.count ? a.value.count < b.value.count : lastIndex(a.key) < lastIndex(b.key)
    }) else { return nil }
    return Summary(
      seconds: median(best.value.map(\.seconds)), width: best.key.w, height: best.key.h,
      steps: best.key.steps, frames: best.key.frames, count: list.count)
  }

  static func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return 0 }
    let mid = sorted.count / 2
    return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
  }

  static func duration(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    return total < 60 ? "\(total) с" : "\(total / 60) мин \(total % 60) с"
  }

  static func steps(_ n: Int) -> String { plural(n, "шаг", "шага", "шагов") }

  static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    let tens = n % 100, ones = n % 10
    let word = (11...14).contains(tens) ? many : ones == 1 ? one : (2...4).contains(ones) ? few : many
    return "\(n) \(word)"
  }
}
