import Foundation
import Testing
@testable import LilArtCore

@Suite struct FolderWatchTests {
  let now = Date(timeIntervalSince1970: 1_000_000)
  let stamp = FileStamp(size: 500, modified: Date(timeIntervalSince1970: 1))

  private func look(
    _ watch: inout FolderWatch, _ path: String = "/m/a.safetensors", ext: String = "safetensors",
    link: FolderWatch.Link = .none, engine: Bool = false, size: Int64 = 500, at time: Date? = nil
  ) -> FolderWatch.Verdict {
    watch.look(path: path, ext: ext, link: link, isEngineFormat: { engine },
               stamp: FileStamp(size: size, modified: stamp.modified), now: time ?? now)
  }

  @Test func anEngineFileIsAModelWhetherOrNotItIsLinked() {
    var watch = FolderWatch()
    #expect(look(&watch, ext: "ckpt", engine: true) == .model)
    #expect(look(&watch, ext: "ckpt", link: .reachable, engine: true) == .model)
  }

  @Test func aLinkWhoseDiskIsUnpluggedIsAway() {
    var watch = FolderWatch()
    #expect(look(&watch, ext: "ckpt", link: .broken, engine: true) == .away)
  }

  @Test func aLinkedFileThatIsNotTheEnginesIsNotOurs() {
    var watch = FolderWatch()
    #expect(look(&watch, link: .reachable) == .foreignLink)
    #expect(look(&watch, ext: "ckpt", link: .reachable, engine: false) == .foreignLink)
  }

  /// A file is imported only after two looks at the same size: until then it may still be copying.
  @Test func aFileIsImportedOnlyOnceItsSizeHasStoppedChanging() {
    var watch = FolderWatch()
    #expect(look(&watch, size: 100) == .growing)
    #expect(look(&watch, size: 200) == .growing)
    #expect(look(&watch, size: 200) == .incoming)
    #expect(look(&watch, size: 300) == .growing)
  }

  @Test func anEmptyFileIsWaitedForThirtySecondsAndThenGivenUp() {
    var watch = FolderWatch()
    #expect(look(&watch, size: 0) == .emptyWaiting)
    #expect(look(&watch, size: 0, at: now.addingTimeInterval(29)) == .emptyWaiting)
    #expect(look(&watch, size: 0, at: now.addingTimeInterval(31)) == .emptyGaveUp)
  }

  @Test func theWaitForAnEmptyFileStartsOverOnceItHasContent() {
    var watch = FolderWatch()
    _ = look(&watch, size: 0)
    _ = look(&watch, size: 100)
    #expect(watch.emptySince["/m/a.safetensors"] == nil)
    #expect(look(&watch, size: 0, at: now.addingTimeInterval(100)) == .emptyWaiting)
  }

  @Test func aFileTheUserCancelledIsLeftAloneUntilItChanges() {
    var watch = FolderWatch()
    watch.cancelled["/m/a.safetensors"] = stamp
    #expect(look(&watch, size: 500) == .cancelledByUser)
    #expect(look(&watch, size: 500) == .cancelledByUser)
    #expect(look(&watch, size: 501) == .growing)
    #expect(watch.cancelled["/m/a.safetensors"] == nil)
  }

  @Test func filesThatLeftTheFolderAreForgotten() {
    var watch = FolderWatch()
    _ = look(&watch, "/m/a.safetensors", size: 100)
    _ = look(&watch, "/m/b.safetensors", size: 0)
    watch.cancelled["/m/c.safetensors"] = stamp
    watch.forget(except: ["/m/a.safetensors"])
    #expect(watch.seenSizes.keys.sorted() == ["/m/a.safetensors"])
    #expect(watch.emptySince.isEmpty)
    #expect(watch.cancelled.isEmpty)
  }

  @Test func aMissingStampCountsAsAnEmptyFile() {
    var watch = FolderWatch()
    let verdict = watch.look(path: "/m/x", ext: "pt", link: .none, isEngineFormat: { false }, stamp: nil, now: now)
    #expect(verdict == .emptyWaiting)
  }
}
