import Foundation
import Testing

@testable import LilArtCore
@testable import LilKitShared

@Suite struct RunTimesTests {
  private func store() -> LilStore {
    LilStore(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
  }

  private func run(_ seconds: Double, _ w: Int = 1024, _ h: Int = 1024, steps: Int = 8, frames: Int = 0) -> RunTime {
    RunTime(width: w, height: h, steps: steps, frames: frames, seconds: seconds)
  }

  @Test func nothingRecordedMeansNoSummary() {
    #expect(RunTimes.summary(of: "a.ckpt", in: store()) == nil)
  }

  @Test func theTypicalTimeIsTheMiddleOneSoOneSlowFirstRunDoesNotSpoilIt() throws {
    let s = store()
    for seconds in [90.0, 31, 30, 32] { RunTimes.add(run(seconds), for: "a.ckpt", in: s) }
    let summary = try #require(RunTimes.summary(of: "a.ckpt", in: s))
    #expect(summary.count == 4)
    #expect(summary.seconds == 31.5)
  }

  /// Only runs at the size and steps used most often are compared, so the number means something.
  @Test func theSummarySpeaksOfTheMostUsedSettings() throws {
    let s = store()
    RunTimes.add(run(30, 1344, 768, steps: 4), for: "a", in: s)
    RunTimes.add(run(32, 1344, 768, steps: 4), for: "a", in: s)
    RunTimes.add(run(120, 2048, 2048, steps: 20), for: "a", in: s)
    let summary = try #require(RunTimes.summary(of: "a", in: s))
    #expect(summary.width == 1344 && summary.height == 768 && summary.steps == 4)
    #expect(summary.seconds == 31)
    #expect(summary.count == 3)
  }

  @Test func onlyTheLastRunsAreKept() {
    let s = store()
    for i in 0..<(RunTimes.limit + 15) { RunTimes.add(run(Double(i)), for: "a", in: s) }
    #expect(RunTimes.all(in: s)["a"]?.count == RunTimes.limit)
  }

  @Test func modelsAreKeptApart() {
    let s = store()
    RunTimes.add(run(10), for: "a", in: s)
    RunTimes.add(run(50), for: "b", in: s)
    #expect(RunTimes.summary(of: "a", in: s)?.seconds == 10)
    #expect(RunTimes.summary(of: "b", in: s)?.seconds == 50)
  }

  @Test func clearingForgetsEverything() {
    let s = store()
    RunTimes.add(run(10), for: "a", in: s)
    RunTimes.clear(in: s)
    #expect(RunTimes.summary(of: "a", in: s) == nil)
  }

  /// Numbers only: nothing of what was drawn may get into the record.
  @Test func aRecordHoldsNumbersOnly() {
    let names = Mirror(reflecting: run(1)).children.compactMap(\.label).sorted()
    #expect(names == ["frames", "height", "seconds", "steps", "width"])
  }

  @Test func theLabelReadsPlainly() {
    let image = RunTimes.Summary(seconds: 31.4, width: 1344, height: 768, steps: 4, frames: 0, count: 12)
    #expect(image.label == "≈ 31 с · 1344×768 · 4 шага · запусков: 12")
    let video = RunTimes.Summary(seconds: 171, width: 1024, height: 576, steps: 8, frames: 37, count: 2)
    #expect(video.label == "≈ 2 мин 51 с · 1024×576 · 37 кадров · 8 шагов · запусков: 2")
  }

  @Test func russianCountsAgree() {
    #expect(RunTimes.steps(1) == "1 шаг")
    #expect(RunTimes.steps(4) == "4 шага")
    #expect(RunTimes.steps(8) == "8 шагов")
    #expect(RunTimes.steps(21) == "21 шаг")
    #expect(RunTimes.steps(12) == "12 шагов")
  }
}
