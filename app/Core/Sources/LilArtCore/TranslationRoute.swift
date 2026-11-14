import Foundation

/// Who may translate a prompt when the one that was asked fails.
enum TranslationRoute {
  enum Provider: Equatable {
    case google, system, local
  }

  /// What may be tried after `provider` failed. A chosen local model is never replaced by
  /// another translator: the error is shown and the prompt is left as it was written.
  static func fallbacks(after provider: Provider) -> [Provider] {
    switch provider {
    case .local: return []
    case .google: return [.system]
    case .system: return []
    }
  }

  static func stopMessage(reason: String) -> String {
    "Prompt остался как написан, другим переводчиком не переводил."
      + (reason.isEmpty ? "" : " Причина: \(reason)")
  }
}
