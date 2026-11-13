import Testing
@testable import LilArtCore

@Suite struct VideoFamilyTests {
  @Test func engineNamesMapToFamiliesAndImageModelsAreNotVideo() {
    #expect(VideoFamily.of("wan_v2.1_14b") == .wanLarge)
    #expect(VideoFamily.of("ltx2.3") == .ltx)
    #expect(VideoFamily.of("minimax_h3") == .minimaxH3)
    #expect(!VideoFamily.isVideo("flux3_5b"))
    #expect(!VideoFamily.isVideo(""))
  }

  /// A clip length the decoder cannot take wastes a whole run, so every answer must sit on the grid.
  @Test func frameCountsAlwaysLandOnTheFamiliesGrid() {
    for family in [VideoFamily.wanSmall, .wanLarge, .ltx, .hunyuan, .minimaxH3] {
      for tenths in 1...200 {
        let frames = family.frames(forSeconds: Double(tenths) / 10, fps: family.fps)
        #expect((frames - family.frameOffset) % family.frameStep == 0 || frames == family.minFrames,
                "\(family) \(tenths) → \(frames)")
        #expect(frames >= family.minFrames && frames <= family.maxFrames)
      }
    }
  }

  @Test func wanTakesFourKPlusOneAndLtxEightKPlusOne() {
    #expect(VideoFamily.wanSmall.frames(forSeconds: 3, fps: 16) == 49)
    #expect(VideoFamily.ltx.frames(forSeconds: 2, fps: 24) == 49)
  }

  @Test func aFixedLengthFamilyIgnoresTheRequest() {
    #expect(VideoFamily.svd.frames(forSeconds: 99, fps: 6) == 25)
  }
}

@Suite struct SpeedProfileTests {
  @Test func distilledModelsAreRecognisedFromTheirNames() {
    #expect(SpeedProfile.guess(file: "wan2.2_i2v_lightx2v_4steps.ckpt", name: "") == .fast)
    #expect(SpeedProfile.guess(file: "dasiwawan22i2v14blightspeed_x_i8x.ckpt", name: "") == .fast)
    #expect(SpeedProfile.guess(file: "x.ckpt", name: "Wan 2.2 4 steps") == .fast)
    #expect(SpeedProfile.guess(file: "model_self_forcing_v1.ckpt", name: "") == .fast)
  }

  @Test func aFullModelIsNotMistakenForADistilledOne() {
    #expect(SpeedProfile.guess(file: "wan_v2.1_14b_i2v_480p_q8p.ckpt", name: "Wan 2.1 14B") == .full)
    #expect(SpeedProfile.guess(file: "hunyuan_video_t2v_720p_q8p.ckpt", name: "HunyuanVideo") == .full)
  }
}

@Suite struct ManualFramesTests {
  @Test func aTypedCountLandsOnTheNearestLengthTheModelTakes() {
    // Wan takes 4k + 1 frames
    #expect(VideoFamily.wanLarge.snap(frames: 48) == 49)
    #expect(VideoFamily.wanLarge.snap(frames: 50) == 49)
    #expect(VideoFamily.wanLarge.snap(frames: 33) == 33)
  }

  @Test func aTypedCountStaysWithinWhatTheModelWasTrainedFor() {
    #expect(VideoFamily.wanLarge.snap(frames: 500) == 81)
    #expect(VideoFamily.wanLarge.snap(frames: 1) == 5)
  }

  @Test func aModelWithOneFixedLengthIgnoresTheTypedCount() {
    #expect(VideoFamily.svd.snap(frames: 60) == 25)
  }

  @Test func lengthFromSecondsIsTheSameSnapOfSecondsTimesRate() {
    #expect(VideoFamily.wanLarge.frames(forSeconds: 3, fps: 16) == VideoFamily.wanLarge.snap(frames: 48))
  }
}
