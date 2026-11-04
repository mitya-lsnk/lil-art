import Testing
@testable import LilArtCore

@Suite struct ImportRulesTests {
  /// An 8-bit download comes out of the importer at 16 bits, twice its size.
  @Test func aResultMuchBiggerThanItsSourceGetsSqueezedBackToEightBits() {
    #expect(ImportRules.cameOutWiderThanItWent(importedBytes: 32_000_000_000, sourceBytes: 16_000_000_000))
    #expect(ImportRules.cameOutWiderThanItWent(importedBytes: 24_100_000_000, sourceBytes: 16_000_000_000))
    #expect(!ImportRules.cameOutWiderThanItWent(importedBytes: 24_000_000_000, sourceBytes: 16_000_000_000))
    #expect(!ImportRules.cameOutWiderThanItWent(importedBytes: 16_000_000_000, sourceBytes: 16_000_000_000))
    // an unreadable source (size 0) must not make every import look "widened"
    #expect(ImportRules.cameOutWiderThanItWent(importedBytes: 1, sourceBytes: 0))
  }

  @Test func aCompressedFileFarBelowWhatThePlanShouldGiveIsRefused() {
    // 8 bits of a 16 GB file: about 8 GB; the floor is half of that
    #expect(ImportRules.smallestPlausibleBytes(inputBytes: 16_000_000_000, bits: 8) == 4_000_000_000)
    #expect(ImportRules.smallestPlausibleBytes(inputBytes: 16_000_000_000, bits: 4) == 2_000_000_000)
    // below 3 bits the plan is still read as 3
    #expect(ImportRules.smallestPlausibleBytes(inputBytes: 16_000_000_000, bits: 1) == 1_500_000_000)
    // and never under ten megabytes
    #expect(ImportRules.smallestPlausibleBytes(inputBytes: 1_000_000, bits: 8) == 10_000_000)
  }

  @Test func theImportersWarningBecomesANoteOfAtMostTwoLinesAnd240Characters() {
    #expect(ImportRules.warningNote("") == nil)
    #expect(ImportRules.warningNote("  \n ") == nil)
    #expect(ImportRules.warningNote("vae missing\ntext encoder missing\nthird")
      == "не докачались нужные модели файлы, без интернета она может не запуститься (vae missing; text encoder missing)")
    let long = String(repeating: "x", count: 500)
    #expect(ImportRules.warningNote(long)!.count == "не докачались нужные модели файлы, без интернета она может не запуститься (".count + 240 + 1)
  }

  /// The importer leaves Wan's picture-to-video models marked text-to-video; 36 input channels say otherwise.
  @Test func aWanModelWith36InputChannelsAndNoMarkTakesAPicture() {
    #expect(ImportRules.needsPictureMark(version: "wan_v2.2_a14b", modifier: "", channels: 36))
    #expect(ImportRules.needsPictureMark(version: "wan_v2.1_14b", modifier: "none", channels: 36))
    #expect(!ImportRules.needsPictureMark(version: "wan_v2.1_14b", modifier: "inpainting", channels: 36))
    #expect(!ImportRules.needsPictureMark(version: "wan_v2.1_14b", modifier: "", channels: 16))
    #expect(!ImportRules.needsPictureMark(version: "wan_v2.1_14b", modifier: "", channels: nil))
    #expect(!ImportRules.needsPictureMark(version: "flux2", modifier: "", channels: 36))
  }

  /// A failed import must leave the folder as it found it, and never delete a model that finished.
  @Test func whatToDoWithTheFolderWhenAnImportFails() {
    #expect(ImportRules.rollback(imported: true, setAside: true, existedBefore: true) == .keepEverything)
    #expect(ImportRules.rollback(imported: false, setAside: true, existedBefore: true) == .putOldCopyBack)
    #expect(ImportRules.rollback(imported: false, setAside: false, existedBefore: false) == .removeWhatThisRunWrote)
    #expect(ImportRules.rollback(imported: false, setAside: false, existedBefore: true) == .leaveAlone)
  }

  @Test func notesAreJoinedWithASemicolon() {
    #expect(ImportRules.joined(nil, "b") == "b")
    #expect(ImportRules.joined("a", "b") == "a; b")
  }
}
