import Foundation

/// The picture engine and the language model (oMLX) do not fit into this Mac's memory together,
/// so they take turns: a generation puts the language model out, a translation puts the engine's
/// model out. These are the rules of that turn-taking, in one place.
enum MemoryTurn {
  /// An engine holding less than this has no model loaded; restarting it would free nothing.
  static let emptyEngineGB = 2.0
  /// After the engine is gone the system needs a moment to count its memory as free, so a
  /// refusal for lack of memory is asked again after these pauses (seconds).
  static let retryPauses: [Double] = [1.5, 3]

  /// Before a request to the language model: must the engine give its memory back first?
  static func engineShouldYield(llmLoaded: Bool, engineGB: Double, busy: Bool) -> Bool {
    !llmLoaded && !busy && engineGB >= emptyEngineGB
  }

  /// Whether the chosen model is in oMLX's memory. "model:profile" is the same model.
  static func llmLoaded(wanted: String, models: [(id: String, loaded: Bool)]) -> Bool {
    let base = wanted.split(separator: ":").first.map(String.init) ?? ""
    return models.contains { $0.loaded && (base.isEmpty || $0.id == base) }
  }
}
