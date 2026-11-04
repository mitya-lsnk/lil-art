import Testing
@testable import LilArtCore

@Suite struct ControlHintsTests {
  @Test func eachKindNamesWhereItsInputComesFrom() {
    for hint in ["canny", "softedge", "mlsd", "tile", "blur", "gray", "lowquality", "inpaint", "ip2p"] {
      #expect(ControlHints.input(for: hint) == .source, "\(hint)")
    }
    #expect(ControlHints.input(for: "shuffle") == .references)
    #expect(ControlHints.input(for: "depth") == .depth)
    #expect(ControlHints.input(for: "pose") == .picture("pose"))
    #expect(ControlHints.input(for: "scribble") == .picture("scribble"))
    #expect(ControlHints.input(for: "color") == .picture("color"))
    #expect(ControlHints.input(for: "lineart") == .picture("custom"))
    #expect(ControlHints.input(for: "something new") == .picture("custom"))
  }

  @Test func everyKindHasAnOnScreenNameAndAnUnknownOneKeepsItsOwn() {
    #expect(ControlHints.label(for: "canny") == "контуры")
    #expect(ControlHints.label(for: "ip2p") == "инструкция")
    #expect(ControlHints.label(for: "color") == "цветовая карта")
    #expect(ControlHints.label(for: "newkind") == "newkind")
    for hint in ControlHints.unionHints { #expect(ControlHints.label(for: hint) != hint, "\(hint)") }
  }
}
