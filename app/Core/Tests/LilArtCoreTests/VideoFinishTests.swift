import Testing
@testable import LilArtCore

@Suite struct VideoFinishTests {
  @Test func asItIsEveryFrameIsItselfAtTheSameRate() {
    let plan = VideoFinish.asIs.plan(frames: 5, fps: 16)
    #expect(plan.fps == 16)
    #expect(plan.frames == (0..<5).map { VideoFinish.Step(index: $0, phase: 0) })
  }

  /// Twice as long: one new frame between every two, shown at the old rate.
  @Test func longerPutsNewFramesBetweenAndKeepsTheRate() {
    let plan = VideoFinish.longer(times: 2).plan(frames: 3, fps: 16)
    #expect(plan.fps == 16)
    #expect(plan.frames == [
      .init(index: 0, phase: 0), .init(index: 0, phase: 0.5), .init(index: 1, phase: 0),
      .init(index: 1, phase: 0.5), .init(index: 2, phase: 0),
    ])
  }

  @Test func longerAlmostDoublesTheCountOfARealClip() {
    #expect(VideoFinish.longer(times: 2).plan(frames: 81, fps: 16).frames.count == 161)
  }

  /// Smoother: the clip lasts as long as before, at the new rate.
  @Test func smootherKeepsTheLengthInSecondsAndRaisesTheRate() {
    let plan = VideoFinish.smoother(fps: 32).plan(frames: 81, fps: 16)
    #expect(plan.fps == 32)
    #expect(plan.frames.count == 161)  // 5 s of motion at 32 a second
    #expect(plan.frames.first == .init(index: 0, phase: 0))
    #expect(plan.frames.last == .init(index: 80, phase: 0))
  }

  @Test func smootherToARateThatIsNotAMultipleLandsBetweenFrames() {
    let plan = VideoFinish.smoother(fps: 24).plan(frames: 5, fps: 16)
    // 4 intervals of 1/16 s = 0.25 s → 6 intervals of 1/24 s
    #expect(plan.frames.count == 7)
    #expect(plan.frames[1].index == 0)
    #expect(abs(plan.frames[1].phase - 2.0 / 3) < 1e-9)
    #expect(plan.frames[3] == .init(index: 2, phase: 0))
    #expect(plan.frames.allSatisfy { $0.index <= 4 && $0.phase >= 0 && $0.phase < 1 })
  }

  @Test func aRateNotAboveTheClipsOwnChangesNothing() {
    #expect(VideoFinish.smoother(fps: 16).plan(frames: 5, fps: 16) == VideoFinish.asIs.plan(frames: 5, fps: 16))
    #expect(VideoFinish.smoother(fps: 12).plan(frames: 5, fps: 16) == VideoFinish.asIs.plan(frames: 5, fps: 16))
  }

  @Test func aClipOfOneFrameHasNothingToPutBetween() {
    #expect(VideoFinish.longer(times: 2).plan(frames: 1, fps: 16).frames == [.init(index: 0, phase: 0)])
  }

  @Test func theChoiceSurvivesBeingSavedAsText() {
    for finish in [VideoFinish.asIs, .smoother(fps: 30), .smoother(fps: 60), .longer(times: 2)] {
      #expect(VideoFinish(text: finish.text) == finish)
    }
    #expect(VideoFinish(text: "nonsense") == .asIs)
    #expect(VideoFinish(text: nil) == .asIs)
  }

  @Test func eachChoiceSaysWhatItWillDo() {
    #expect(VideoFinish.asIs.label == "как есть")
    #expect(VideoFinish.smoother(fps: 30).label == "плавнее · 30 к/с")
    #expect(VideoFinish.longer(times: 2).label == "длиннее · ×2")
  }
}
