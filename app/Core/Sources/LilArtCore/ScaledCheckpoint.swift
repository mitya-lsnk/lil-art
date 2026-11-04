import Foundation

/// ComfyUI's "fp8 scaled" checkpoints keep most weights as 8-bit floats plus one multiplier per
/// layer (`weight_scale`), with a small JSON note beside each (`comfy_quant`). The engine's
/// importer reads the 8-bit numbers but knows nothing of the multipliers, so the weights come out
/// hundreds of times too large and the model paints pure noise.
///
/// Before import such a file is rewritten with the multipliers applied, as a plain 16-bit
/// safetensors the importer understands.
enum ScaledCheckpoint {
  enum Failure: Error {
    case unreadable
    case unsupported(String)
    case noSpace(Double)
  }

  struct Entry {
    let dtype: String
    let shape: [Int]
    /// The product of the shape, already checked for overflow.
    let count: Int
    let start: Int
    let end: Int
  }

  struct Header {
    let entries: [String: Entry]
    let metadata: Any?
    let dataStart: Int
  }

  /// Everything in the header comes from the file, so every number is checked before it is used
  /// for a seek, a read or a multiplication: a damaged file must come back as nil, never trap.
  static func header(of url: URL) -> Header? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let size = try? handle.seekToEnd(), (try? handle.seek(toOffset: 0)) != nil,
      let lengthBytes = try? handle.read(upToCount: 8), lengthBytes.count == 8
    else { return nil }
    let declared = UInt64(
      littleEndian: lengthBytes.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) })
    // compared as UInt64 first: converting a huge value to Int would trap
    guard declared > 0, declared < 200_000_000, declared <= size - 8 else { return nil }
    let length = Int(declared)
    guard let data = try? handle.read(upToCount: length), data.count == length,
      let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return nil }
    let dataStart = 8 + length
    let dataSize = Int(clamping: size) - dataStart
    var entries: [String: Entry] = [:]
    for (key, value) in json where key != "__metadata__" {
      guard let item = value as? [String: Any], let dtype = item["dtype"] as? String,
        let shape = item["shape"] as? [Int], let offsets = item["data_offsets"] as? [Int],
        offsets.count == 2, let count = elementCount(shape),
        offsets[0] >= 0, offsets[0] <= offsets[1], offsets[1] <= dataSize,
        sizeMatches(dtype, count: count, bytes: offsets[1] - offsets[0])
      else { return nil }
      entries[key] = Entry(
        dtype: dtype, shape: shape, count: count, start: offsets[0], end: offsets[1])
    }
    return Header(entries: entries, metadata: json["__metadata__"], dataStart: dataStart)
  }

  /// The number of elements, or nil for a negative size or a product too big for an Int.
  private static func elementCount(_ shape: [Int]) -> Int? {
    var total = 1
    for dimension in shape {
      guard dimension >= 0 else { return nil }
      let (product, overflow) = total.multipliedReportingOverflow(by: dimension)
      if overflow { return nil }
      total = product
    }
    return total
  }

  private static let elementBytes: [String: Int] = [
    "BOOL": 1, "U8": 1, "I8": 1, "I16": 2, "U16": 2, "F16": 2, "BF16": 2,
    "I32": 4, "U32": 4, "F32": 4, "I64": 8, "U64": 8, "F64": 8,
  ]

  /// Safetensors writes exactly shape times element size bytes for each tensor. A file that says
  /// otherwise is damaged; a kind of element this does not know is not judged.
  private static func sizeMatches(_ dtype: String, count: Int, bytes: Int) -> Bool {
    guard let width = elementBytes[dtype] ?? (dtype.hasPrefix("F8_") ? 1 : nil) else { return true }
    let (expected, overflow) = count.multipliedReportingOverflow(by: width)
    return !overflow && expected == bytes
  }

  /// True when the file carries per-layer multipliers the importer would ignore.
  static func needsDequantizing(_ url: URL) -> Bool {
    guard url.pathExtension.lowercased() == "safetensors", let header = header(of: url) else {
      return false
    }
    let hasScales = header.entries.keys.contains { $0.hasSuffix(".weight_scale") || $0 == "scaled_fp8" }
    let hasEightBit = header.entries.values.contains { eightBit.contains($0.dtype) }
    return hasScales && hasEightBit
  }

  private static let eightBit: Set<String> = ["F8_E4M3", "F8_E5M2", "I8"]

  private static func isDropped(_ key: String) -> Bool {
    key.hasSuffix(".weight_scale") || key.hasSuffix(".comfy_quant") || key.hasSuffix(".input_scale")
      || key == "scaled_fp8"
  }

  static func dequantize(
    _ input: URL, to output: URL, progress: (Double) -> Void, shouldStop: () -> Bool = { false }
  ) throws {
    guard let header = header(of: input) else { throw Failure.unreadable }
    let reader = try FileHandle(forReadingFrom: input)
    defer { try? reader.close() }

    try refuseOtherFormats(header, reader)
    let (plans, layout, size) = try plan(header, reader)
    try requireSpace(for: size, beside: output)

    FileManager.default.createFile(atPath: output.path, contents: nil)
    let writer = try FileHandle(forWritingTo: output)
    defer { try? writer.close() }
    try writeHeader(layout, to: writer)

    let totalBytes = max(1, plans.reduce(0) { $0 + ($1.entry.end - $1.entry.start) })
    var doneBytes = 0
    for plan in plans {
      if shouldStop() { throw CancellationError() }
      try reader.seek(toOffset: UInt64(header.dataStart + plan.entry.start))
      let step: (Int) -> Void = { n in
        doneBytes += n
        progress(Double(doneBytes) / Double(totalBytes))
      }
      if let scale = plan.scale {
        try widen(plan, scale: scale, from: reader, to: writer, step: step)
      } else {
        try copyThrough(plan.entry.end - plan.entry.start, from: reader, to: writer, step: step)
      }
    }
  }

  /// One tensor of the new file: where it comes from and the multipliers to apply (nil: copy as is).
  private struct Plan {
    let key: String
    let entry: Entry
    let scale: [Float]?
  }

  /// Only the plain per-layer formats are handled; anything else is refused, never guessed.
  private static func refuseOtherFormats(_ header: Header, _ reader: FileHandle) throws {
    for (key, entry) in header.entries where key.hasSuffix(".comfy_quant") {
      // a note is a few bytes of JSON; a large one is not a note
      guard entry.end - entry.start <= 1_000_000 else { throw Failure.unreadable }
      try reader.seek(toOffset: UInt64(header.dataStart + entry.start))
      let note = try reader.read(upToCount: entry.end - entry.start) ?? Data()
      if let json = (try? JSONSerialization.jsonObject(with: note)) as? [String: Any],
        let format = json["format"] as? String,
        !["float8_e4m3fn", "float8_e5m2"].contains(format)
      {
        throw Failure.unsupported(format)
      }
    }
  }

  /// The tensors that stay, in order, the header of the file that will be written, and its data size.
  private static func plan(_ header: Header, _ reader: FileHandle) throws -> ([Plan], [String: Any], Int) {
    var plans: [Plan] = []
    var layout: [String: Any] = [:]
    if let metadata = header.metadata { layout["__metadata__"] = metadata }
    var offset = 0
    for key in header.entries.keys.sorted() where !isDropped(key) {
      guard let entry = header.entries[key] else { continue }
      let base = key.hasSuffix(".weight") ? String(key.dropLast(".weight".count)) : key
      let scaleEntry = header.entries[base + ".weight_scale"]
      let converts = entry.dtype.hasPrefix("F8_") || (entry.dtype == "I8" && scaleEntry != nil)
      var scale: [Float]?
      var bytes = entry.end - entry.start
      var dtype = entry.dtype
      if converts {
        scale = try multipliers(for: key, entry, scaleEntry, header, reader)
        bytes = entry.count * 2
        dtype = "F16"
      }
      let (next, overflow) = offset.addingReportingOverflow(bytes)
      if overflow { throw Failure.unreadable }
      layout[key] = ["dtype": dtype, "shape": entry.shape, "data_offsets": [offset, next]]
      plans.append(Plan(key: key, entry: entry, scale: scale))
      offset = next
    }
    guard offset < (Int.max - 2_000_000_000) / 2 else { throw Failure.unreadable }
    return (plans, layout, offset)
  }

  /// One multiplier for the whole layer or one per row; anything else is refused.
  private static func multipliers(
    for key: String, _ entry: Entry, _ scaleEntry: Entry?, _ header: Header, _ reader: FileHandle
  ) throws -> [Float] {
    let values = try scaleEntry.map { try readScale(reader, header, $0) } ?? [1]
    let rows = max(1, entry.shape.first ?? 1)
    guard values.count == 1 || values.count == rows else {
      throw Failure.unsupported("множители по блокам в \(key)")
    }
    return values
  }

  private static func requireSpace(for size: Int, beside output: URL) throws {
    let free =
      (try? output.deletingLastPathComponent().resourceValues(
        forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
      .volumeAvailableCapacityForImportantUsage ?? Int64.max
    // the rewritten file, plus the engine's own copy the importer writes next
    let needed = Int64(size) * 2 + 2_000_000_000
    guard free > needed else { throw Failure.noSpace(Double(needed) / 1_073_741_824) }
  }

  private static func writeHeader(_ layout: [String: Any], to writer: FileHandle) throws {
    var headerData = try JSONSerialization.data(withJSONObject: layout)
    while headerData.count % 8 != 0 { headerData.append(0x20) }
    var length = UInt64(headerData.count).littleEndian
    try writer.write(contentsOf: Data(bytes: &length, count: 8))
    try writer.write(contentsOf: headerData)
  }

  private static let chunk = 1 << 24

  /// An 8-bit tensor written as 16-bit numbers with its multipliers applied.
  private static func widen(
    _ plan: Plan, scale: [Float], from reader: FileHandle, to writer: FileHandle, step: (Int) -> Void
  ) throws {
    let table = decodeTable(plan.entry.dtype)
    let count = plan.entry.count
    let perRow = max(1, count / max(1, plan.entry.shape.first ?? 1))
    var done = 0
    while done < count {
      let n = min(chunk, count - done)
      guard let source = try reader.read(upToCount: n), source.count == n else {
        throw Failure.unreadable
      }
      var converted = Data(count: n * 2)
      source.withUnsafeBytes { raw in
        converted.withUnsafeMutableBytes { out in
          let bytes = raw.bindMemory(to: UInt8.self)
          let values = out.bindMemory(to: Float16.self)
          for i in 0..<n {
            let multiplier = scale.count == 1 ? scale[0] : scale[(done + i) / perRow]
            values[i] = Float16(table[Int(bytes[i])] * multiplier)
          }
        }
      }
      try writer.write(contentsOf: converted)
      done += n
      step(n)
    }
  }

  private static func copyThrough(
    _ size: Int, from reader: FileHandle, to writer: FileHandle, step: (Int) -> Void
  ) throws {
    var left = size
    while left > 0 {
      let n = min(chunk, left)
      guard let data = try reader.read(upToCount: n), data.count == n else {
        throw Failure.unreadable
      }
      try writer.write(contentsOf: data)
      left -= n
      step(n)
    }
  }

  static func readScale(_ reader: FileHandle, _ header: Header, _ entry: Entry) throws
    -> [Float]
  {
    // one multiplier per layer or per row is tiny; a huge one would only be read into memory
    guard entry.end - entry.start <= 64_000_000 else { throw Failure.unreadable }
    try reader.seek(toOffset: UInt64(header.dataStart + entry.start))
    guard let data = try reader.read(upToCount: entry.end - entry.start) else {
      throw Failure.unreadable
    }
    switch entry.dtype {
    case "F32":
      return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    case "F16":
      return data.withUnsafeBytes { $0.bindMemory(to: Float16.self).map { Float($0) } }
    default:
      throw Failure.unsupported("множители в формате \(entry.dtype)")
    }
  }

  /// Every possible byte decoded once.
  static func decodeTable(_ dtype: String) -> [Float] {
    (0..<256).map { value -> Float in
      let byte = UInt8(value)
      let sign: Float = byte & 0x80 != 0 ? -1 : 1
      switch dtype {
      case "I8":
        return Float(Int8(bitPattern: byte))
      case "F8_E5M2":
        let exponent = Int((byte >> 2) & 0x1F)
        let mantissa = Float(byte & 0x3)
        if exponent == 0 { return sign * mantissa / 4 * pow(2, -14) }
        if exponent == 31 { return mantissa == 0 ? sign * .infinity : .nan }
        return sign * (1 + mantissa / 4) * pow(2, Float(exponent - 15))
      default:  // F8_E4M3, the "fn" variant: no infinities
        let exponent = Int((byte >> 3) & 0xF)
        let mantissa = Float(byte & 0x7)
        if exponent == 0 { return sign * mantissa / 8 * pow(2, -6) }
        if exponent == 15 && mantissa == 7 { return .nan }
        return sign * (1 + mantissa / 8) * pow(2, Float(exponent - 7))
      }
    }
  }
}
