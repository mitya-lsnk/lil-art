import Foundation

/// Which added parts (VAE, text encoder, …) each model uses instead of its standard ones. Kept
/// per model file: a retrained part is a choice made for a particular model.
enum PartPrefs {
  private static let key = "model.parts"

  static func stored(_ model: String) -> [ModelParts.Slot: String] {
    let all = LilStore.standard.dictionary(forKey: key) as? [String: [String: String]]
    var out: [ModelParts.Slot: String] = [:]
    for (raw, file) in all?[model] ?? [:] {
      if let slot = ModelParts.Slot(rawValue: raw) { out[slot] = file }
    }
    return out
  }

  static func save(_ file: String?, _ slot: ModelParts.Slot, for model: String) {
    var all = (LilStore.standard.dictionary(forKey: key) as? [String: [String: String]]) ?? [:]
    var mine = all[model] ?? [:]
    mine[slot.rawValue] = file
    all[model] = mine.isEmpty ? nil : mine
    LilStore.standard.set(all, forKey: key)
  }
}
