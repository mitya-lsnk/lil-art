import Testing

@testable import LilArtCore

@Suite struct PromptStyleTests {
  @Test func wordsInThePromptNameTheStyle() {
    #expect(PromptStyle.detect(in: "фурри лиса в лесу") == [.furry])
    #expect(PromptStyle.detect(in: "антро волк, портрет") == [.furry])
    #expect(PromptStyle.detect(in: "anthro fox, forest") == [.furry])
    #expect(PromptStyle.detect(in: "аниме девушка под дождём") == [.anime])
    #expect(PromptStyle.detect(in: "3д модель робота") == [.render3d])
    #expect(PromptStyle.detect(in: "3D render of a car") == [.render3d])
    #expect(PromptStyle.detect(in: "фото старика, профессиональная съёмка") == [.photo])
    #expect(PromptStyle.detect(in: "реализм, кошка на окне") == [.photo])
    #expect(PromptStyle.detect(in: "photorealistic portrait") == [.photo])
  }

  /// A word is a word: "фотон" is not a photo, "антресоль" is not anthro.
  @Test func onlyWholeWordsCount() {
    #expect(PromptStyle.detect(in: "фотон летит").isEmpty)
    #expect(PromptStyle.detect(in: "антресоль с коробками").isEmpty)
    #expect(PromptStyle.detect(in: "animal on a hill").isEmpty)
  }

  @Test func caseAndEndingsDoNotMatter() {
    #expect(PromptStyle.detect(in: "ФУРРИ") == [.furry])
    #expect(PromptStyle.detect(in: "в стиле аниме-арт") == [.anime])
    #expect(PromptStyle.detect(in: "фотография заката") == [.photo])
    #expect(PromptStyle.detect(in: "реалистичный пейзаж") == [.photo])
  }

  /// "3d furry" is both: furry characters drawn as a 3D render.
  @Test func twoStylesAreBothKeptInAFixedOrder() {
    #expect(PromptStyle.detect(in: "3d фурри") == [.furry, .render3d])
    #expect(PromptStyle.detect(in: "anime, furry") == [.furry, .anime])
  }

  @Test func noStyleWordsMeanNoHint() {
    #expect(PromptStyle.detect(in: "кошка на окне").isEmpty)
    #expect(PromptStyle.auto.hint(for: "кошка на окне") == nil)
  }

  @Test func autoFollowsTheWordsAndAChoiceIgnoresThem() {
    #expect(PromptStyle.auto.resolved(for: "аниме кот") == [.anime])
    #expect(PromptStyle.photo.resolved(for: "аниме кот") == [.photo])
    #expect(PromptStyle.none.resolved(for: "аниме кот").isEmpty)
  }

  @Test func theHintSaysWhatThePictureIs() throws {
    let furry = try #require(PromptStyle.furry.hint(for: ""))
    #expect(furry.contains("anthro"))
    let photo = try #require(PromptStyle.photo.hint(for: ""))
    #expect(photo.lowercased().contains("photograph"))
    let both = try #require(PromptStyle.auto.hint(for: "3d фурри"))
    #expect(both.contains("anthro") && both.contains("3D render"))
  }

  /// The improver keeps its own rules and gets the style on top; without a style nothing changes.
  @Test func instructionsCarryTheStyleOnlyWhenThereIsOne() {
    #expect(PromptChat.instructions(hasFrame: false, style: nil) == PromptChat.plain)
    let styled = PromptChat.instructions(hasFrame: false, style: "STYLE")
    #expect(styled.hasPrefix(PromptChat.plain) && styled.hasSuffix("STYLE"))
    #expect(PromptChat.instructions(hasFrame: true, style: "STYLE").hasPrefix(PromptChat.fromFrame))
  }

  @Test func everyStyleHasAShortNameForTheMenu() {
    for style in PromptStyle.allCases {
      #expect(!style.label.isEmpty && style.label.count <= 6, "\(style)")
    }
  }

  @Test func anUnknownSavedStyleIsAuto() {
    #expect(PromptStyle(saved: "watercolour") == .auto)
    #expect(PromptStyle(saved: nil) == .auto)
    #expect(PromptStyle(saved: "anime") == .anime)
  }
}
