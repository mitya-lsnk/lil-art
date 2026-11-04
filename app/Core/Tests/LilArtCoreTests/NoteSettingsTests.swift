import Testing
@testable import LilArtCore

@Suite struct NoteSettingsTests {
  /// The sentence FLUX.3 klein's catalog note carries; at shift 1 its pictures came out as noise.
  @Test func readsStepsGuidanceAndShiftFromTheMakersNote() {
    let note = "Start with 16 steps, Text Guidance 1 and Shift 16. Released under the licence."
    let found = NoteSettings(note)
    #expect(found.steps == 16)
    #expect(found.cfg == 1)
    #expect(found.shift == 16)
  }

  @Test func baseModelNoteHasItsOwnNumbers() {
    let found = NoteSettings("it requires classifier-free guidance; start with 50 steps, Text Guidance 4 and Shift 16.")
    #expect(found.steps == 50)
    #expect(found.cfg == 4)
    #expect(found.shift == 16)
  }

  @Test func decimalsAndOtherWordingsAreRead() {
    let found = NoteSettings("Use CFG of 3.5 with shift 2.5")
    #expect(found.cfg == 3.5)
    #expect(found.shift == 2.5)
  }

  @Test func aNoteWithoutNumbersLeavesEverythingUnset() {
    let found = NoteSettings("A fast model for sketches. Shifts the style a little.")
    #expect(found.steps == nil)
    #expect(found.cfg == nil)
    #expect(found.shift == nil)
  }
}
