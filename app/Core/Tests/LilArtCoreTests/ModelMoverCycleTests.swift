import Foundation
import Testing
@testable import LilArtCore

private func folder() -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

/// Moving a model to an external disk and back: the weights must never be lost on the way.
@Suite struct ModelMoverCycleTests {
  @Test func outAndBackLeavesTheFolderExactlyAsItWas() throws {
    let models = folder(), disk = folder()
    let weights = Data((0..<5000).map { UInt8($0 % 251) })
    try weights.write(to: models.appendingPathComponent("big.ckpt"))
    try Data([9]).write(to: models.appendingPathComponent("big.ckpt-tensordata"))
    let names = ModelMover.expand(["big.ckpt"], in: models)

    var progress = 0.0
    try ModelMover.copyOut(names, from: models, to: disk, progress: { progress = $0 }, shouldStop: { false })
    #expect(progress == 1)
    // copying alone leaves the folder untouched: the engine may go on using the files
    #expect(ModelMover.linkTarget(models.appendingPathComponent("big.ckpt")) == nil)

    try ModelMover.linkOut(names, from: models, to: disk)
    #expect(ModelMover.linkTarget(models.appendingPathComponent("big.ckpt"))?.path.hasPrefix(disk.standardizedFileURL.path) == true)
    #expect(try Data(contentsOf: models.appendingPathComponent("big.ckpt")) == weights)

    let back = try ModelMover.copyBack(names, to: models, progress: { _ in }, shouldStop: { false })
    #expect(back.count == 2)
    try ModelMover.swapBack(back)
    #expect(ModelMover.linkTarget(models.appendingPathComponent("big.ckpt")) == nil)
    #expect(try Data(contentsOf: models.appendingPathComponent("big.ckpt")) == weights)
    #expect(try Data(contentsOf: models.appendingPathComponent("big.ckpt-tensordata")) == Data([9]))
    #expect(!FileManager.default.fileExists(atPath: disk.appendingPathComponent("big.ckpt").path))
  }

  @Test func aCopyAlreadyWholeOnTheDiskIsNotMadeAgain() throws {
    let models = folder(), disk = folder()
    try Data(repeating: 1, count: 1000).write(to: models.appendingPathComponent("m.ckpt"))
    try Data(repeating: 1, count: 1000).write(to: disk.appendingPathComponent("m.ckpt"))
    var copied: Int64 = 0
    try ModelMover.copyOut(["m.ckpt"], from: models, to: disk, progress: { copied += Int64($0) }, shouldStop: { true })
    #expect(copied == 1)  // reported as done without touching shouldStop, which would have thrown
  }

  @Test func linkOutRefusesWhenTheCopyIsNotThere() throws {
    let models = folder(), disk = folder()
    try Data(repeating: 1, count: 1000).write(to: models.appendingPathComponent("m.ckpt"))
    #expect(throws: ModelMover.Failure.self) {
      try ModelMover.linkOut(["m.ckpt"], from: models, to: disk)
    }
    // and the original is still a real file
    #expect(ModelMover.linkTarget(models.appendingPathComponent("m.ckpt")) == nil)
    #expect(FileManager.default.fileExists(atPath: models.appendingPathComponent("m.ckpt").path))
  }

  @Test func bringingBackFromAnUnpluggedDiskIsRefusedBeforeAnythingChanges() throws {
    let models = folder()
    let link = models.appendingPathComponent("gone.ckpt")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/Volumes/NoSuchDisk/gone.ckpt"))
    #expect(throws: ModelMover.Failure.self) {
      _ = try ModelMover.copyBack(["gone.ckpt"], to: models, progress: { _ in }, shouldStop: { false })
    }
    #expect(ModelMover.linkTarget(link) != nil)
  }

  @Test func copyingOutToADiskThatIsNotThereIsRefused() {
    let models = folder()
    #expect(throws: ModelMover.Failure.self) {
      try ModelMover.copyOut(["m.ckpt"], from: models, to: URL(fileURLWithPath: "/Volumes/NoSuchDisk/models"), progress: { _ in }, shouldStop: { false })
    }
  }
}
