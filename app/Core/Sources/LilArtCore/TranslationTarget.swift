import Foundation

/// What the «Перевести» and «Улучшить» buttons act on. They work on the text the person is
/// looking at: on the English side that is the English, which may have been corrected by hand,
/// and a fresh translation of the Russian must not replace those corrections.
enum TranslationTarget: Equatable {
  /// Make English of the Russian text.
  case translate(String)
  /// Add detail to the English that is on screen.
  case improveEnglish(String)
  /// The English is already there and matches the Russian: translating again would only put the
  /// old translation back over whatever was corrected.
  case nothingToTranslate

  static func choose(
    improve: Bool, showingEnglish: Bool, english: String, englishIsCurrent: Bool, prompt: String
  ) -> TranslationTarget {
    guard showingEnglish, !english.isEmpty, englishIsCurrent else { return .translate(prompt) }
    return improve ? .improveEnglish(english) : .nothingToTranslate
  }
}
