import Foundation
import Testing
@testable import LilArtCore

private struct Tensor {
  let name: String
  let dtype: String
  let shape: [Int]
  let bytes: [UInt8]
}

private func write(_ tensors: [Tensor]) -> URL {
  var header: [String: Any] = [:]
  var data = Data()
  for t in tensors {
    header[t.name] = ["dtype": t.dtype, "shape": t.shape, "data_offsets": [data.count, data.count + t.bytes.count]]
    data.append(contentsOf: t.bytes)
  }
  let json = try! JSONSerialization.data(withJSONObject: header)
  var file = Data()
  var n = UInt64(json.count).littleEndian
  withUnsafeBytes(of: &n) { file.append(contentsOf: $0) }
  file.append(json)
  file.append(data)
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".safetensors")
  try! file.write(to: url)
  return url
}

private func f32(_ values: [Float]) -> [UInt8] {
  values.flatMap { v in withUnsafeBytes(of: v.bitPattern.littleEndian) { Array($0) } }
}

/// Reads a converted file back: every tensor's name, dtype and (for F16) values.
private func read(_ url: URL) throws -> [String: (dtype: String, values: [Float])] {
  let header = try #require(ScaledCheckpoint.header(of: url))
  let data = try Data(contentsOf: url)
  var out: [String: (String, [Float])] = [:]
  for (key, entry) in header.entries {
    let bytes = data[(header.dataStart + entry.start)..<(header.dataStart + entry.end)]
    let values: [Float] = entry.dtype == "F16"
      ? bytes.withUnsafeBytes { $0.bindMemory(to: Float16.self).map { Float($0) } } : []
    out[key] = (entry.dtype, values)
  }
  return out
}

private func output() -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".safetensors")
}

@Suite struct DequantizeTests {
  // F8_E4M3: 0x38 = 1, 0x40 = 2, 0xB8 = -1, 0x00 = 0
  private let weight = Tensor(name: "a.weight", dtype: "F8_E4M3", shape: [2, 2], bytes: [0x38, 0x40, 0xB8, 0x00])

  @Test func oneMultiplierPerLayerIsAppliedAndTheScaleTensorsAreDropped() throws {
    let input = write([
      weight,
      Tensor(name: "a.weight_scale", dtype: "F32", shape: [1], bytes: f32([0.5])),
      Tensor(name: "a.comfy_quant", dtype: "U8", shape: [36], bytes: Array(#"{"format":"float8_e4m3fn","group":0}"#.utf8)),
      Tensor(name: "norm.weight", dtype: "F16", shape: [2], bytes: [0x00, 0x3C, 0x00, 0x40]),  // 1.0, 2.0
    ])
    let out = output()
    var last = 0.0
    try ScaledCheckpoint.dequantize(input, to: out, progress: { last = $0 })
    let result = try read(out)
    #expect(Set(result.keys) == ["a.weight", "norm.weight"])
    #expect(result["a.weight"]?.dtype == "F16")
    #expect(result["a.weight"]?.values == [0.5, 1.0, -0.5, 0])
    #expect(result["norm.weight"]?.values == [1, 2])
    #expect(last == 1)
  }

  @Test func oneMultiplierPerRowIsAppliedRowByRow() throws {
    let input = write([
      weight,
      Tensor(name: "a.weight_scale", dtype: "F32", shape: [2], bytes: f32([1, 10])),
    ])
    let out = output()
    try ScaledCheckpoint.dequantize(input, to: out, progress: { _ in })
    #expect(try read(out)["a.weight"]?.values == [1, 2, -10, 0])
  }

  @Test func eightBitWeightsWithoutAScaleAreWidenedAsTheyAre() throws {
    let out = output()
    try ScaledCheckpoint.dequantize(write([weight]), to: out, progress: { _ in })
    #expect(try read(out)["a.weight"]?.values == [1, 2, -1, 0])
  }

  @Test func halfPrecisionMultipliersAreUnderstoodToo() throws {
    let input = write([
      weight, Tensor(name: "a.weight_scale", dtype: "F16", shape: [1], bytes: [0x00, 0x40]),  // 2.0
    ])
    let out = output()
    try ScaledCheckpoint.dequantize(input, to: out, progress: { _ in })
    #expect(try read(out)["a.weight"]?.values == [2, 4, -2, 0])
  }

  @Test func aFormatOtherThanFloat8IsRefusedNotGuessed() {
    let input = write([
      weight,
      Tensor(name: "a.comfy_quant", dtype: "U8", shape: [20], bytes: Array(#"{"format":"nvfp4"}"#.utf8) + [0x20, 0x20]),
    ])
    #expect(throws: ScaledCheckpoint.Failure.self) {
      try ScaledCheckpoint.dequantize(input, to: output(), progress: { _ in })
    }
  }

  @Test func blockMultipliersAreRefused() {
    let input = write([
      weight, Tensor(name: "a.weight_scale", dtype: "F32", shape: [3], bytes: f32([1, 2, 3])),
    ])
    #expect(throws: ScaledCheckpoint.Failure.self) {
      try ScaledCheckpoint.dequantize(input, to: output(), progress: { _ in })
    }
  }

  @Test func aStoppedConversionThrowsCancellation() {
    #expect(throws: CancellationError.self) {
      try ScaledCheckpoint.dequantize(write([weight]), to: output(), progress: { _ in }, shouldStop: { true })
    }
  }

  @Test func anUnreadableFileIsReportedAsUnreadable() {
    let bogus = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    #expect(throws: ScaledCheckpoint.Failure.self) {
      try ScaledCheckpoint.dequantize(bogus, to: output(), progress: { _ in })
    }
  }
}
