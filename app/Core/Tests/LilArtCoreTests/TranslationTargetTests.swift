import Testing
@testable import LilArtCore

@Suite struct TranslationTargetTests {
  private func choose(
    improve: Bool, showingEnglish: Bool, english: String = "", current: Bool = true, prompt: String = "кот"
  ) -> TranslationTarget {
    TranslationTarget.choose(
      improve: improve, showingEnglish: showingEnglish, english: english, englishIsCurrent: current, prompt: prompt)
  }

  @Test func onTheRussianSideTheRussianIsTranslatedOrImproved() {
    #expect(choose(improve: false, showingEnglish: false) == .translate("кот"))
    #expect(choose(improve: true, showingEnglish: false, english: "a cat") == .translate("кот"))
  }

  /// The corrections typed into the English must not be replaced by a fresh copy of the old translation.
  @Test func onTheEnglishSideImproveWorksOnTheEnglishThatIsThere() {
    #expect(choose(improve: true, showingEnglish: true, english: "a cat, corrected") == .improveEnglish("a cat, corrected"))
  }

  @Test func onTheEnglishSideTranslateHasNothingToDoAndKeepsTheCorrections() {
    #expect(choose(improve: false, showingEnglish: true, english: "a cat, corrected") == .nothingToTranslate)
  }

  @Test func ifTheRussianChangedSinceTheEnglishIsOutOfDateAndTheRussianIsTranslatedAgain() {
    #expect(choose(improve: false, showingEnglish: true, english: "a cat", current: false, prompt: "собака") == .translate("собака"))
    #expect(choose(improve: true, showingEnglish: true, english: "a cat", current: false, prompt: "собака") == .translate("собака"))
  }

  @Test func withoutAnyEnglishTheEnglishSideCannotBeShownSoTheRussianIsUsed() {
    #expect(choose(improve: true, showingEnglish: true, english: "") == .translate("кот"))
  }
}
