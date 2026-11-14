import Testing
@testable import LilArtCore

@Suite struct TranslationRouteTests {
  /// Whoever chose their own model chose it for what it will and will not do: another
  /// translator quietly doing the job would drop words the model was picked to keep.
  @Test func aChosenLocalModelIsNeverReplacedByAnotherTranslator() {
    #expect(TranslationRoute.fallbacks(after: .local).isEmpty)
  }

  @Test func googleMayFallBackToTheSystemTranslator() {
    #expect(TranslationRoute.fallbacks(after: .google) == [.system])
  }

  @Test func theSystemTranslatorIsTheLastResort() {
    #expect(TranslationRoute.fallbacks(after: .system).isEmpty)
  }

  @Test func theWordsAreEnoughToTellTheStory() {
    #expect(TranslationRoute.stopMessage(reason: "сервер ответил 507").contains("507"))
    #expect(TranslationRoute.stopMessage(reason: "").contains("как написан"))
    #expect(TranslationRoute.stopMessage(reason: "").contains("другим переводчиком не переводил"))
  }
}
