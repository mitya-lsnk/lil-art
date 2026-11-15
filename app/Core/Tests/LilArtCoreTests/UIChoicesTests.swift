import Foundation
import Testing
@testable import LilArtCore

/// What is kept between launches of the window: what can be switched, never what was typed.
@Suite struct UIChoicesTests {
  /// The allow-list. A field added here is a decision that it is a choice and not something the
  /// person typed; adding one without changing this test fails it.
  @Test func onlyChoicesAreKept() {
    let names = Mirror(reflecting: UIChoices()).children.compactMap(\.label).sorted()
    #expect(
      names == [
        "aspect", "megapixels", "model", "preset", "pro", "quality", "sampler",
        "showSizePad", "tab", "upscaleFactor", "upscaleOn", "upscaler", "videoModel", "videoPro",
        "videoSampler", "videoSizeIndex",
      ])
  }

  @Test func nothingTypedCanBeInTheEncodedBytes() throws {
    var choices = UIChoices()
    choices.model = "krea.ckpt"
    choices.pro = true
    let text = String(decoding: try #require(choices.encoded()), as: UTF8.self)
    for typed in ["prompt", "negative", "seed", "width", "height", "steps", "cfg", "frames", "fps", "lora"] {
      #expect(!text.lowercased().contains(typed), "\(typed)")
    }
  }

  @Test func theChoicesComeBackAsTheyWereSaved() {
    var choices = UIChoices()
    choices.tab = "video"
    choices.pro = true
    choices.videoPro = true
    choices.aspect = "wide"
    choices.megapixels = 1.5
    choices.videoSizeIndex = 2
    #expect(UIChoices.decode(choices.encoded()) == choices)
  }

  @Test func nothingOrGarbageMeansNothingToRestore() {
    #expect(UIChoices.decode(nil) == nil)
    #expect(UIChoices.decode(Data("not json".utf8)) == nil)
  }

  /// A file written by a later or earlier build with other fields must still be read.
  /// A LoRA is never part of what comes back: a launch starts with none chosen and none switched on.
  @Test func loRAsOfAnOlderFileAreLeftOut() {
    let data = Data(#"{"pro": true, "loraOn": true, "loras": ["a.ckpt"]}"#.utf8)
    let choices = UIChoices.decode(data)
    #expect(choices?.pro == true)
    #expect(String(decoding: choices?.encoded() ?? Data(), as: UTF8.self).contains("lora") == false)
  }

  @Test func unknownFieldsAreIgnoredAndMissingOnesTakeTheirDefaults() {
    let data = Data(#"{"pro": true, "somethingNew": 5}"#.utf8)
    let choices = UIChoices.decode(data)
    #expect(choices?.pro == true)
    #expect(choices?.model == "")
  }
}

@Suite struct GenerateLabelTests {
  @Test func theButtonSaysWhatItWillDoInOneShortLine() {
    #expect(VideoFinish.asIs.buttonLabel == nil)
    #expect(VideoFinish.smoother(fps: 24).buttonLabel == "плавно 24 к/с")
    #expect(VideoFinish.longer(times: 2).buttonLabel == "длиннее ×2")
  }
}
