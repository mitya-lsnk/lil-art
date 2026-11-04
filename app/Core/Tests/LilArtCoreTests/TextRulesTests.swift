import Testing
@testable import LilArtCore

@Suite struct KeepingTermsTests {
  let glossary = TextRules.defaultGlossary

  /// The translator dropped «лифчик» from a prompt and the picture came out without one.
  @Test func aWordTheTranslationLostIsPutBack() {
    let out = TextRules.keepingTerms(of: "девушка снимает лифчик", in: "a girl takes off", glossary: glossary)
    #expect(out == "a girl takes off, bra")
  }

  @Test func aWordThatSurvivedIsNotAddedAgain() {
    let out = TextRules.keepingTerms(of: "лифчик", in: "a bra on the table", glossary: glossary)
    #expect(out == "a bra on the table")
  }

  @Test func braInsideAnotherWordDoesNotCountAsPresent() {
    let out = TextRules.keepingTerms(of: "лифчик", in: "a bracelet and a zebra", glossary: glossary)
    #expect(out == "a bracelet and a zebra, bra")
  }

  @Test func caseEndingsAndYoAreCovered() {
    let out = TextRules.keepingTerms(of: "Без Лифчиков, обнажённая", in: "without anything", glossary: glossary)
    #expect(out.contains("bra"))
    #expect(out.contains("nude"))
  }

  @Test func anyVariantOfAnEntryCountsAsKept() {
    let out = TextRules.keepingTerms(of: "грудь", in: "a woman with her chest bare", glossary: glossary)
    #expect(out == "a woman with her chest bare")
  }

  @Test func existingPunctuationIsRespectedWhenAppending() {
    let out = TextRules.keepingTerms(of: "лифчик", in: "a girl.", glossary: glossary)
    #expect(out == "a girl. bra")
  }

  @Test func malformedGlossaryLinesAreSkipped() {
    let out = TextRules.keepingTerms(of: "лифчик", in: "x", glossary: "лифчик\n= bra\nлифчик =\n")
    #expect(out == "x")
  }

  @Test func aSourceWithoutGlossaryWordsIsLeftAlone() {
    #expect(TextRules.keepingTerms(of: "красное яблоко", in: "a red apple", glossary: glossary) == "a red apple")
  }
}

@Suite struct PictureNumbersTests {
  @Test func everyWordingBecomesTheOneTheEditModelsWereTaught() {
    #expect(TextRules.pictureNumbers("copy the style of picture 2") == "copy the style of image 2")
    #expect(TextRules.pictureNumbers("use photo 1 and pic 3") == "use image 1 and image 3")
    #expect(TextRules.pictureNumbers("from Photograph #2") == "from image 2")
    #expect(TextRules.pictureNumbers("pictures 1 and 2") == "images 1 and 2")
  }

  @Test func wordsWithoutANumberAreLeftAlone() {
    #expect(TextRules.pictureNumbers("a picture of a cat") == "a picture of a cat")
    #expect(TextRules.pictureNumbers("image 12") == "image 12")
  }
}
