import Foundation
#if canImport(LilKitShared)
  @testable import LilKitShared
#endif

/// What a LoRA remembers about itself: the strength it was last used at and its trigger words,
/// which go after the prompt whenever the LoRA is in use.
enum LoRAPrefs {
  private static let key = "lora.prefs"

  private static func all(_ store: LilStore) -> [String: [String: Any]] {
    store.dictionary(forKey: key) as? [String: [String: Any]] ?? [:]
  }

  private static func set(_ value: Any, _ field: String, for file: String, in store: LilStore) {
    var table = all(store)
    table[file, default: [:]][field] = value
    store.set(table, forKey: key)
  }

  static func weight(for file: String, in store: LilStore = .standard) -> Double? {
    (all(store)[file]?["weight"] as? NSNumber)?.doubleValue
  }

  static func setWeight(_ weight: Double, for file: String, in store: LilStore = .standard) {
    set(weight, "weight", for: file, in: store)
  }

  static func words(for file: String, in store: LilStore = .standard) -> String {
    all(store)[file]?["words"] as? String ?? ""
  }

  static func setWords(_ words: String, for file: String, in store: LilStore = .standard) {
    set(words, "words", for: file, in: store)
  }

  /// What to put after the prompt: the comma-separated words of every LoRA in use, each once,
  /// leaving out those already written in any of `texts` (the prompt, its English).
  static func suffix(words: [String], alreadyIn texts: [String]) -> String {
    let written = texts.map { $0.lowercased() }
    var seen = Set<String>()
    var out: [String] = []
    for piece in words.flatMap({ $0.split(separator: ",") }) {
      let word = piece.trimmingCharacters(in: .whitespacesAndNewlines)
      let lower = word.lowercased()
      guard !word.isEmpty, !seen.contains(lower), !written.contains(where: { $0.contains(lower) })
      else { continue }
      seen.insert(lower)
      out.append(word)
    }
    return out.map { ", " + $0 }.joined()
  }
}

/// How much the engine may keep in memory between runs ("держать модель в памяти").
///
/// Measured on a 24 GB Mac with a 12.9 GB model (2026-11-13): kept copies pushed memory out to
/// disk, and the runs after the first took 71 and 90 s instead of 40; with nothing kept every
/// run took 40 s and the swap did not grow. So the kept amount is cut to what leaves room for
/// the system (8 GB) and for the model at work with its encoder and decoder (1.35 × its size).
enum CachePolicy {
  static func safeGB(machineGB: Double, modelGB: Double) -> Double {
    let room = (machineGB - 8 - 1.35 * modelGB).rounded(.down)
    // room that cannot hold the model itself keeps nothing useful
    return room >= modelGB ? room : 0
  }

  /// The chosen value, cut down for the chosen model. An unknown size (0) changes nothing.
  static func clamp(_ chosen: Double, machineGB: Double, modelGB: Double) -> Double {
    guard modelGB > 0 else { return chosen }
    return min(chosen, safeGB(machineGB: machineGB, modelGB: modelGB))
  }
}

/// Which half of a two-model video (Wan 2.2: high, then low) a LoRA acts on.
enum LoRAStage: String, CaseIterable, Hashable {
  case both, high, low

  init(saved: String?) { self = saved.flatMap(LoRAStage.init(rawValue:)) ?? .both }

  var label: String {
    switch self {
    case .both: return "обе"
    case .high: return "high"
    case .low: return "low"
    }
  }

  struct Saved: Equatable {
    var file: String
    var weight: Double
    var stage: LoRAStage

    static func encode(_ picks: [Saved]) -> [[String: Any]] {
      picks.map { ["file": $0.file, "weight": $0.weight, "stage": $0.stage.rawValue] }
    }

    static func decode(_ raw: Any?) -> [Saved] {
      (raw as? [[String: Any]] ?? []).compactMap { item in
        guard let file = item["file"] as? String, !file.isEmpty else { return nil }
        return Saved(
          file: file, weight: (item["weight"] as? NSNumber)?.doubleValue ?? 0.6,
          stage: LoRAStage(saved: item["stage"] as? String))
      }
    }
  }
}
