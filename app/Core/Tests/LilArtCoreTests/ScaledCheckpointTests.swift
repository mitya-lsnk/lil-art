import Foundation
import Testing
@testable import LilArtCore

/// Builds a safetensors file the way the format says: 8 bytes of header length, the JSON header,
/// then the numbers.
private func safetensors(_ header: [String: Any], data: Data = Data(count: 64), declaring length: UInt64? = nil) -> URL {
  let json = try! JSONSerialization.data(withJSONObject: header)
  var file = Data()
  var n = (length ?? UInt64(json.count)).littleEndian
  withUnsafeBytes(of: &n) { file.append(contentsOf: $0) }
  file.append(json)
  file.append(data)
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".safetensors")
  try! file.write(to: url)
  return url
}

@Suite struct ScaledCheckpointTests {
  private let plain: [String: Any] = [
    "layer.weight": ["dtype": "F16", "shape": [2, 4], "data_offsets": [0, 16]],
  ]

  @Test func readsAWellFormedHeader() throws {
    let header = try #require(ScaledCheckpoint.header(of: safetensors(plain)))
    let entry = try #require(header.entries["layer.weight"])
    #expect(entry.shape == [2, 4])
    #expect(entry.count == 8)
    #expect(entry.end - entry.start == 16)
  }

  @Test func aDeclaredLengthBeyondTheFileIsRefusedNotTrapped() {
    #expect(ScaledCheckpoint.header(of: safetensors(plain, declaring: 5_000_000)) == nil)
    #expect(ScaledCheckpoint.header(of: safetensors(plain, declaring: UInt64.max)) == nil)
    #expect(ScaledCheckpoint.header(of: safetensors(plain, declaring: 0)) == nil)
  }

  @Test func offsetsPastTheDataAreRefused() {
    let bad: [String: Any] = ["w": ["dtype": "F16", "shape": [2, 4], "data_offsets": [0, 4096]]]
    #expect(ScaledCheckpoint.header(of: safetensors(bad)) == nil)
  }

  @Test func aSizeThatDoesNotMatchItsShapeIsRefused() {
    let bad: [String: Any] = ["w": ["dtype": "F16", "shape": [2, 4], "data_offsets": [0, 10]]]
    #expect(ScaledCheckpoint.header(of: safetensors(bad)) == nil)
  }

  @Test func aShapeTooBigForAnIntIsRefused() {
    let huge = Int.max / 2
    let bad: [String: Any] = ["w": ["dtype": "F16", "shape": [huge, 4], "data_offsets": [0, 8]]]
    #expect(ScaledCheckpoint.header(of: safetensors(bad)) == nil)
  }

  @Test func aFileOfScaledEightBitWeightsNeedsConverting() {
    let scaled: [String: Any] = [
      "a.weight": ["dtype": "F8_E4M3", "shape": [2, 2], "data_offsets": [0, 4]],
      "a.weight_scale": ["dtype": "F32", "shape": [1], "data_offsets": [4, 8]],
    ]
    #expect(ScaledCheckpoint.needsDequantizing(safetensors(scaled)))
  }

  @Test func plainSixteenBitOrScaleLessEightBitFilesAreLeftAlone() {
    let eightBitOnly: [String: Any] = ["a.weight": ["dtype": "F8_E4M3", "shape": [2, 2], "data_offsets": [0, 4]]]
    #expect(!ScaledCheckpoint.needsDequantizing(safetensors(plain)))
    #expect(!ScaledCheckpoint.needsDequantizing(safetensors(eightBitOnly)))
  }

  @Test func eightBitFloatsDecodeToTheirKnownValues() {
    let e4m3 = ScaledCheckpoint.decodeTable("F8_E4M3")
    #expect(e4m3[0x00] == 0)
    #expect(e4m3[0x38] == 1)  // exponent 7, mantissa 0
    #expect(e4m3[0xB8] == -1)
    #expect(e4m3[0x7E] == 448)  // the largest finite value
    #expect(e4m3[0x7F].isNaN)
    let e5m2 = ScaledCheckpoint.decodeTable("F8_E5M2")
    #expect(e5m2[0x3C] == 1)
    #expect(e5m2[0x7C] == .infinity)
    let int8 = ScaledCheckpoint.decodeTable("I8")
    #expect(int8[0x7F] == 127)
    #expect(int8[0x80] == -128)
  }
}

/// The older "scaled fp8" naming (kijai, many Wan and Flux checkpoints): the multiplier of a
/// layer is `<layer>.scale_weight`, beside an unused `<layer>.scale_input`.
@Suite struct LegacyScaledNamesTests {
  /// a.weight = four 8-bit numbers (1, 2, 1, 2), a.scale_weight = 0.5, a.scale_input = 3.
  private func legacyFile(withMarker: Bool = true) -> URL {
    var header: [String: Any] = [
      "a.weight": ["dtype": "F8_E4M3", "shape": [2, 2], "data_offsets": [0, 4]],
      "a.scale_weight": ["dtype": "F32", "shape": [], "data_offsets": [4, 8]],
      "a.scale_input": ["dtype": "F32", "shape": [], "data_offsets": [8, 12]],
      "a.bias": ["dtype": "F32", "shape": [2], "data_offsets": [12, 20]],
    ]
    if withMarker { header["scaled_fp8"] = ["dtype": "F8_E4M3", "shape": [0], "data_offsets": [20, 20]] }
    var data = Data([0x38, 0x40, 0x38, 0x40])
    for value in [Float(0.5), Float(3), Float(7), Float(8)] {
      var bits = value.bitPattern.littleEndian
      withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
    }
    return safetensors(header, data: data)
  }

  private func floats(_ url: URL, _ key: String) throws -> [Float] {
    let header = try #require(ScaledCheckpoint.header(of: url))
    let entry = try #require(header.entries[key])
    let bytes = try Data(contentsOf: url)
    let slice = bytes.subdata(in: (header.dataStart + entry.start)..<(header.dataStart + entry.end))
    if entry.dtype == "F16" {
      return stride(from: 0, to: slice.count, by: 2).map {
        Float(Float16(bitPattern: UInt16(slice[$0]) | UInt16(slice[$0 + 1]) << 8))
      }
    }
    return stride(from: 0, to: slice.count, by: 4).map {
      Float(bitPattern: UInt32(slice[$0]) | UInt32(slice[$0 + 1]) << 8 | UInt32(slice[$0 + 2]) << 16 | UInt32(slice[$0 + 3]) << 24)
    }
  }

  @Test func aFileWithScaleWeightNeedsConvertingWithOrWithoutTheMarker() {
    #expect(ScaledCheckpoint.needsDequantizing(legacyFile()))
    #expect(ScaledCheckpoint.needsDequantizing(legacyFile(withMarker: false)))
  }

  /// The real case: the engine reads the raw 8-bit numbers and paints noise unless the layer's multiplier is applied.
  @Test func theWeightIsTheEightBitNumbersTimesItsScaleWeight() throws {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".safetensors")
    try ScaledCheckpoint.dequantize(legacyFile(), to: out, progress: { _ in })
    #expect(try floats(out, "a.weight") == [0.5, 1.0, 0.5, 1.0])
  }

  @Test func theScaleTensorsDoNotTravelOnAndOtherTensorsDo() throws {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".safetensors")
    try ScaledCheckpoint.dequantize(legacyFile(), to: out, progress: { _ in })
    let header = try #require(ScaledCheckpoint.header(of: out))
    #expect(Set(header.entries.keys) == ["a.weight", "a.bias"])
    #expect(try floats(out, "a.bias") == [7, 8])
  }
}
