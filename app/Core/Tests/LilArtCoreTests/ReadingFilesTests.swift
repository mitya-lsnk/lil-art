import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import LilArtCore

/// A real 4×3 picture written by ImageIO, optionally with a PNG text chunk or an EXIF comment.
private func picture(
  _ type: UTType = .png, properties: [CFString: Any] = [:], orientation: Int? = nil
) -> URL {
  let context = CGContext(
    data: nil, width: 4, height: 3, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  let ext = type == .png ? ".png" : type == .tiff ? ".tiff" : ".jpg"
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ext)
  let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
  var all = properties
  if let orientation { all[kCGImagePropertyOrientation] = orientation }
  CGImageDestinationAddImage(destination, context.makeImage()!, all as CFDictionary)
  CGImageDestinationFinalize(destination)
  return url
}

@Suite struct PixelSizeTests {
  @Test func theSizeComesFromTheHeader() {
    let size = RegionLayout.pixelSize(picture())
    #expect(size == CGSize(width: 4, height: 3))
  }

  @Test func aPictureTurnedAQuarterReportsTheSizeItShowsAt() {
    let size = RegionLayout.pixelSize(picture(.jpeg, orientation: 6))
    #expect(size == CGSize(width: 3, height: 4))
  }

  @Test func aMissingFileHasNoSize() {
    #expect(RegionLayout.pixelSize(URL(fileURLWithPath: "/nonexistent/x.png")) == nil)
  }
}

@Suite struct ReadSettingsFromAFileTests {
  @Test func aPictureWithoutAnySettingsGivesNothing() {
    #expect(SettingsImport.read(picture()) == nil)
  }

  /// ImageIO writes a "Comment" only into XMP, so the real chunk Draw Things writes is built by hand.
  @Test func aDrawThingsCommentInThePNGIsFound() throws {
    var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    let body = Array("Comment".utf8) + [0] + Array(#"{"c":"a boat","steps":8,"scale":1}"#.utf8)
    for (type, chunk) in [("tEXt", body), ("IEND", [])] as [(String, [UInt8])] {
      var length = UInt32(chunk.count).bigEndian
      withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
      data.append(contentsOf: Array(type.utf8) + chunk + [0, 0, 0, 0])
    }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
    try data.write(to: url)
    let found = try #require(SettingsImport.read(url))
    #expect(found.prompt == "a boat")
    #expect(found.steps == 8)
  }

  @Test func anA1111TextInTheExifUserCommentIsFound() throws {
    let url = picture(.jpeg, properties: [
      kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "a hill\nSteps: 12, Seed: 3"],
    ])
    let found = try #require(SettingsImport.read(url))
    #expect(found.prompt == "a hill")
    #expect(found.steps == 12 && found.seed == 3)
  }

  @Test func theTIFFDescriptionIsTriedLast() throws {
    let url = picture(.tiff, properties: [
      kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFImageDescription: "a lake\nSteps: 5"],
    ])
    #expect(try #require(SettingsImport.read(url)).steps == 5)
  }

  @Test func aFileThatIsNotAPictureGivesNothing() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
    try Data("not a picture".utf8).write(to: url)
    #expect(SettingsImport.read(url) == nil)
  }
}

@Suite struct MoreComfyTests {
  @Test func strengthShiftAndTheUNETLoaderAreRead() throws {
    let graph = """
      {"1":{"class_type":"KSamplerAdvanced","inputs":{"noise_seed":7,"steps":4,"cfg":1,"sampler_name":"euler","scheduler":"simple","denoise":0.6,"positive":["2",0],"negative":["3",0]}},
       "2":{"class_type":"Wrap","inputs":{"cond":["4",0]}},
       "4":{"class_type":"CLIPTextEncodeSDXL","inputs":{"text_g":"deep prompt"}},
       "3":{"class_type":"CLIPTextEncode","inputs":{"text":""}},
       "5":{"class_type":"ModelSamplingAuraFlow","inputs":{"shift":3.5}},
       "6":{"class_type":"EmptySD3LatentImage","inputs":{"width":1024,"height":1536}},
       "7":{"class_type":"UNETLoader","inputs":{"unet_name":"flux.safetensors"}}}
      """
    let found = try #require(SettingsImport.fromComfy(graph))
    #expect(found.seed == 7 && found.strength == 0.6 && found.shift == 3.5)
    #expect(found.prompt == "deep prompt")
    #expect(found.negative == nil)
    #expect(found.width == 1024 && found.height == 1536)
    #expect(found.model == "flux.safetensors")
  }
}

@Suite struct VideoFamilyNamesTests {
  @Test func everyEngineFamilyNameMapsToItsFamily() {
    let names: [String: VideoFamily] = [
      "wan_v2.1_1.3b": .wanSmall, "wan_v2.1_14b": .wanLarge, "wan_v2.2_5b": .wan22Small,
      "hunyuan_video": .hunyuan, "ltx2": .ltx, "ltx2.3": .ltx, "svd_i2v": .svd,
      "longcat_video_avatar_v1.5": .longcat, "minimax_h3": .minimaxH3,
    ]
    for (raw, family) in names { #expect(VideoFamily.of(raw) == family, "\(raw)") }
    #expect(VideoFamily.of("wan_v2.2_a14b") == nil)
  }
}
