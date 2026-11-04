import Foundation
import Testing
@testable import LilArtCore

/// A PNG made only of its signature and the given chunks: enough for the metadata reader.
private func png(_ chunks: [(String, [UInt8])]) -> Data {
  var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
  for (type, body) in chunks + [("IEND", [])] {
    var length = UInt32(body.count).bigEndian
    withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
    data.append(contentsOf: Array(type.utf8))
    data.append(contentsOf: body)
    data.append(contentsOf: [0, 0, 0, 0])  // checksum: the reader does not check it
  }
  return data
}

@Suite struct PNGTextTests {
  @Test func tEXtIsReadAsUTF8EvenThoughTheFormatSaysLatin1() {
    let body = Array("parameters".utf8) + [0] + Array("красная лиса".utf8)
    #expect(SettingsImport.pngTexts(png([("tEXt", body)]))["parameters"] == "красная лиса")
  }

  @Test func tEXtThatIsNotUTF8FallsBackToLatin1() {
    let body = Array("note".utf8) + [0] + [0x63, 0x61, 0x66, 0xE9]  // "café" in Latin-1
    #expect(SettingsImport.pngTexts(png([("tEXt", body)]))["note"] == "café")
  }

  @Test func iTXtPlainAndCompressedAreBothRead() throws {
    let plain = Array("Comment".utf8) + [0, 0, 0] + [0] + [0] + Array("привет".utf8)
    let deflate = try (Data("hello world hello world".utf8) as NSData).compressed(using: .zlib) as Data
    let zlib = [UInt8]([0x78, 0x9C]) + [UInt8](deflate) + [0, 0, 0, 0]
    let compressed = Array("Zipped".utf8) + [0, 1, 0] + [0] + [0] + zlib
    let found = SettingsImport.pngTexts(png([("iTXt", plain), ("iTXt", compressed)]))
    #expect(found["Comment"] == "привет")
    #expect(found["Zipped"] == "hello world hello world")
  }

  @Test func zTXtIsInflated() throws {
    let deflate = try (Data("a cat".utf8) as NSData).compressed(using: .zlib) as Data
    let body = Array("parameters".utf8) + [0, 0] + [0x78, 0x9C] + [UInt8](deflate) + [0, 0, 0, 0]
    #expect(SettingsImport.pngTexts(png([("zTXt", body)]))["parameters"] == "a cat")
  }

  @Test func aTruncatedChunkStopsTheReadWithoutTrapping() {
    var data = png([("tEXt", Array("k".utf8) + [0] + Array("v".utf8))])
    data.removeLast(30)
    _ = SettingsImport.pngTexts(data)
    #expect(SettingsImport.pngTexts(Data([0x89, 0x50])).isEmpty)
  }
}

@Suite struct A1111Tests {
  let text = """
    a red fox, studio light
    Negative prompt: blurry, low quality
    Steps: 28, Sampler: DPM++ 2M Karras, Schedule type: Karras, CFG scale: 6.5, Seed: 123456, Size: 832x1216, Model: foxMix, Denoising strength: 0.45, Clip skip: 2
    """

  @Test func readsPromptNegativeAndEveryNumber() throws {
    let found = try #require(SettingsImport.fromA1111(text))
    #expect(found.prompt == "a red fox, studio light")
    #expect(found.negative == "blurry, low quality")
    #expect(found.steps == 28)
    #expect(found.cfg == 6.5)
    #expect(found.sampler == "DPM++ 2M Karras")
    #expect(found.scheduler == "Karras")
    #expect(found.seed == 123456)
    #expect(found.width == 832 && found.height == 1216)
    #expect(found.model == "foxMix")
    #expect(found.strength == 0.45)
    #expect(found.clipSkip == 2)
    #expect(found.origin == "A1111")
  }

  @Test func aQuotedValueMayContainCommas() throws {
    let found = try #require(SettingsImport.fromA1111("x\nSteps: 20, Model hash: \"a, b\", Seed: 5"))
    #expect(found.steps == 20 && found.seed == 5)
  }

  @Test func textWithoutAStepsLineIsNotA1111() {
    #expect(SettingsImport.fromA1111("just a prompt") == nil)
  }

  @Test func aNegativePromptMayRunOverSeveralLines() throws {
    let found = try #require(SettingsImport.fromA1111("p\nNegative prompt: a\nb\nSteps: 10"))
    #expect(found.negative == "a\nb")
  }
}

@Suite struct DrawThingsAndComfyTests {
  @Test func drawThingsCommentIsRead() throws {
    let json = #"{"c":"a cat","uc":"","steps":16,"scale":1,"sampler":"Euler A Trailing","seed":42,"size":"1024x1024","shift":16,"model":"flux_3_klein_q8p.ckpt"}"#
    let found = try #require(SettingsImport.fromDrawThings(json))
    #expect(found.prompt == "a cat")
    #expect(found.negative == nil)
    #expect(found.steps == 16 && found.cfg == 1 && found.shift == 16)
    #expect(found.width == 1024 && found.height == 1024)
  }

  @Test func plainTextIsNotADrawThingsComment() {
    #expect(SettingsImport.fromDrawThings("not json") == nil)
    #expect(SettingsImport.fromDrawThings(#"{"other":1}"#) == nil)
  }

  @Test func comfyGraphGivesNumbersAndFollowsTheWiresToThePrompts() throws {
    let graph = """
      {"3":{"class_type":"KSampler","inputs":{"seed":99,"steps":20,"cfg":7,"sampler_name":"euler_ancestral","scheduler":"normal","denoise":1,"positive":["6",0],"negative":["7",0]}},
       "6":{"class_type":"CLIPTextEncode","inputs":{"text":"a lighthouse"}},
       "7":{"class_type":"CLIPTextEncode","inputs":{"text":"ugly"}},
       "5":{"class_type":"EmptyLatentImage","inputs":{"width":768,"height":512}},
       "4":{"class_type":"CheckpointLoaderSimple","inputs":{"ckpt_name":"m.safetensors"}}}
      """
    let found = try #require(SettingsImport.fromComfy(graph))
    #expect(found.prompt == "a lighthouse")
    #expect(found.negative == "ugly")
    #expect(found.steps == 20 && found.cfg == 7 && found.seed == 99)
    #expect(found.sampler == "euler_ancestral")
    #expect(found.width == 768 && found.height == 512)
    #expect(found.model == "m.safetensors")
  }

  @Test func aGraphWithoutASamplerGivesNothing() {
    #expect(SettingsImport.fromComfy(#"{"1":{"class_type":"LoadImage","inputs":{}}}"#) == nil)
  }
}

@Suite struct CivitaiTests {
  @Test func imageNumberComesFromThePageOrFromTheFileAddress() {
    #expect(SettingsImport.civitaiImageID(URL(string: "https://civitai.com/images/123456?x=1")!) == 123456)
    #expect(SettingsImport.civitaiImageID(URL(string: "https://image.civitai.com/abc/width=450/987654.jpeg")!) == 987654)
    #expect(SettingsImport.civitaiImageID(URL(string: "https://example.com/images/1")!) == nil)
  }

  @Test func theMedianOfStatsPicksTheMiddleValue() {
    #expect(SettingsImport.CivitaiStats.median([30, 20, 25, 40, 10]) == 25)
    #expect(SettingsImport.CivitaiStats.median([Int]()) == nil)
  }
}
