import Foundation
#if canImport(LilKitShared)
  // LilStore is internal to the shared file: this package is only ever built to be tested.
  @testable import LilKitShared
#endif

/// What the program is allowed to keep: settings, and the engine's technical log. A record of
/// what the person did (prompts typed, runs made) is not kept unless they saved it themselves.
/// This clears away what older versions wrote.
enum Records {
  /// Settings that once recorded actions and that nothing writes any more.
  static let retired = ["assist.history", "llm.released", "session.last", "session.restore"]

  /// The snapshot of the whole last session held what was being worked on, the prompt among it;
  /// what the window keeps now is only its choices (`UIChoices`).
  static func purge(_ store: LilStore) {
    for key in retired { store.removeObject(forKey: key) }
  }

  /// The prompt history of earlier versions, a file of every prompt ever sent to generate.
  static func removeOldFiles(in root: URL) {
    try? FileManager.default.removeItem(at: root.appendingPathComponent("history.json"))
  }
}
