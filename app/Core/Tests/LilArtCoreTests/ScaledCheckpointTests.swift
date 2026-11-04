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
