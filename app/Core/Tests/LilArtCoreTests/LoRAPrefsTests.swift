import Foundation
import Testing
@testable import LilArtCore
@testable import LilKitShared

private func store() -> LilStore {
  LilStore(file: FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString).appendingPathComponent("settings.json"))
}

@Suite struct LoRAPrefsTests {
  @Test func aLoRARemembersItsStrengthAndItsWords() {
    let s = store()
    LoRAPrefs.setWeight(0.85, for: "a.ckpt", in: s)
    LoRAPrefs.setWords("ohwx woman, film grain", for: "a.ckpt", in: s)
    #expect(LoRAPrefs.weight(for: "a.ckpt", in: s) == 0.85)
    #expect(LoRAPrefs.words(for: "a.ckpt", in: s) == "ohwx woman, film grain")
  }

  @Test func aLoRANobodyTouchedHasNoStrengthAndNoWords() {
    let s = store()
    #expect(LoRAPrefs.weight(for: "new.ckpt", in: s) == nil)
    #expect(LoRAPrefs.words(for: "new.ckpt", in: s) == "")
  }

  @Test func oneLoRAsSettingsDoNotTouchAnothers() {
    let s = store()
    LoRAPrefs.setWeight(0.3, for: "a.ckpt", in: s)
    LoRAPrefs.setWords("b word", for: "b.ckpt", in: s)
    #expect(LoRAPrefs.weight(for: "b.ckpt", in: s) == nil)
    #expect(LoRAPrefs.words(for: "a.ckpt", in: s) == "")
    #expect(LoRAPrefs.weight(for: "a.ckpt", in: s) == 0.3)
  }

  @Test func theWordsOfEveryLoRAInUseGoAfterThePrompt() {
    let out = LoRAPrefs.suffix(words: ["ohwx woman, film grain", "p4rty"], alreadyIn: ["a portrait"])
    #expect(out == ", ohwx woman, film grain, p4rty")
  }

  @Test func aWordAlreadyWrittenIsNotRepeatedWhateverItsCase() {
    let out = LoRAPrefs.suffix(words: ["OHWX woman, film grain"], alreadyIn: ["portrait of ohwx woman"])
    #expect(out == ", film grain")
  }

  @Test func theSameWordFromTwoLoRAsGoesInOnce() {
    #expect(LoRAPrefs.suffix(words: ["film grain", "Film Grain, p4rty"], alreadyIn: [""]) == ", film grain, p4rty")
  }

  @Test func withNoWordsNothingIsAdded() {
    #expect(LoRAPrefs.suffix(words: ["", "  ,  "], alreadyIn: ["a cat"]) == "")
  }

  /// A word found in the English that will be sent counts as written, too.
  @Test func theEnglishSideCountsAsWritten() {
    #expect(LoRAPrefs.suffix(words: ["p4rty"], alreadyIn: ["вечеринка", "a p4rty at night"]) == "")
  }
}

@Suite struct CachePolicyTests {
  /// Measured on 24 GB with a 12.9 GB model: any kept copy pushed memory to disk and slowed runs.
  @Test func aBigModelOnASmallMacKeepsNothing() {
    #expect(CachePolicy.safeGB(machineGB: 24, modelGB: 12.9) == 0)
  }

  @Test func aSmallModelMayStayInMemory() {
    #expect(CachePolicy.safeGB(machineGB: 24, modelGB: 4) == 10)
  }

  @Test func aBigMacHasRoomForABigModel() {
    #expect(CachePolicy.safeGB(machineGB: 64, modelGB: 12.9) == 38)
  }

  @Test func roomSmallerThanTheModelIsNoRoomAtAll() {
    // 24 − 8 − 1.35×9 = 3.85: a copy of a 9 GB model does not fit, so keeping makes no sense
    #expect(CachePolicy.safeGB(machineGB: 24, modelGB: 9) == 0)
  }

  @Test func theChosenValueIsCutDownToWhatIsSafe() {
    #expect(CachePolicy.clamp(18, machineGB: 24, modelGB: 12.9) == 0)
    #expect(CachePolicy.clamp(8, machineGB: 24, modelGB: 4) == 8)
    #expect(CachePolicy.clamp(18, machineGB: 24, modelGB: 4) == 10)
  }

  @Test func anUnknownModelSizeChangesNothing() {
    #expect(CachePolicy.clamp(18, machineGB: 24, modelGB: 0) == 18)
  }
}

@Suite struct LoRAStageTests {
  @Test func aStageSurvivesBeingSavedAndAnUnknownOneMeansBoth() {
    for stage in LoRAStage.allCases { #expect(LoRAStage(rawValue: stage.rawValue) == stage) }
    #expect(LoRAStage(saved: "low") == .low)
    #expect(LoRAStage(saved: "nonsense") == .both)
    #expect(LoRAStage(saved: nil) == .both)
  }

  @Test func theLabelsNameTheHalves() {
    #expect(LoRAStage.allCases.map(\.label) == ["обе", "high", "low"])
  }

  /// What is kept between launches for the video LoRAs: file, strength, half.
  @Test func aListOfPicksSurvivesTheSettingsFile() {
    let picks = [
      LoRAStage.Saved(file: "fix_high.ckpt", weight: 1, stage: .high),
      LoRAStage.Saved(file: "style.ckpt", weight: 0.6, stage: .both),
    ]
    #expect(LoRAStage.Saved.decode(LoRAStage.Saved.encode(picks)) == picks)
    #expect(LoRAStage.Saved.decode(nil) == [])
    #expect(LoRAStage.Saved.decode([["weight": 1.0]]) == [])  // no file, no pick
  }
}
