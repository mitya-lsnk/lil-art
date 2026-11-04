import Foundation
import Testing
@testable import LilArtCore

private func folder() -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

@Suite struct ModelMoverTests {
  @Test func expandAddsTheWeightsFileBesideTheModel() throws {
    let dir = folder()
    try Data([1]).write(to: dir.appendingPathComponent("big.ckpt"))
    try Data([1]).write(to: dir.appendingPathComponent("big.ckpt-tensordata"))
    try Data([1]).write(to: dir.appendingPathComponent("small.ckpt"))
    #expect(ModelMover.expand(["big.ckpt", "small.ckpt", "missing.ckpt"], in: dir)
      == ["big.ckpt", "big.ckpt-tensordata", "small.ckpt"])
  }

  @Test func expandKeepsBrokenLinksSoTheyCanBeReported() throws {
    let dir = folder()
    try FileManager.default.createSymbolicLink(
      at: dir.appendingPathComponent("gone.ckpt"), withDestinationURL: URL(fileURLWithPath: "/nonexistent/disk/gone.ckpt"))
    #expect(ModelMover.expand(["gone.ckpt"], in: dir) == ["gone.ckpt"])
  }

  @Test func linkTargetSaysWhereALinkPointsAndNilForAPlainFile() throws {
    let dir = folder()
    let real = dir.appendingPathComponent("real.ckpt")
    try Data([1]).write(to: real)
    let link = dir.appendingPathComponent("link.ckpt")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    #expect(ModelMover.linkTarget(link)?.lastPathComponent == "real.ckpt")
    #expect(ModelMover.linkTarget(real) == nil)
  }

  @Test func copyReportsEveryByteAndLeavesNoPartialFile() throws {
    let dir = folder()
    let source = dir.appendingPathComponent("a.bin")
    try Data(repeating: 7, count: 100_000).write(to: source)
    let target = dir.appendingPathComponent("b.bin")
    var seen: Int64 = 0
    try ModelMover.copy(source, to: target, progress: { seen += $0 }, shouldStop: { false })
    #expect(seen == 100_000)
    #expect(try Data(contentsOf: target) == Data(repeating: 7, count: 100_000))
    #expect(!FileManager.default.fileExists(atPath: target.path + ".part"))
  }

  @Test func aStoppedCopyLeavesNothingBehind() throws {
    let dir = folder()
    let source = dir.appendingPathComponent("a.bin")
    try Data(repeating: 7, count: 1000).write(to: source)
    let target = dir.appendingPathComponent("b.bin")
    #expect(throws: CancellationError.self) {
      try ModelMover.copy(source, to: target, progress: { _ in }, shouldStop: { true })
    }
    #expect(!FileManager.default.fileExists(atPath: target.path))
    #expect(!FileManager.default.fileExists(atPath: target.path + ".part"))
  }
}
