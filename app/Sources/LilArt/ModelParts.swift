import Foundation
import NNC

/// Parts of a model a person can swap for their own copy: the VAE that turns the result into a
/// picture, the text encoders that read the prompt, the image encoder of picture-driven models.
///
/// Draw Things keeps each such part in a file of its own and names it in the model's
/// description (the catalog and custom.json: `autoencoder`, `text_encoder`, …). What people
/// share are retrained copies in ComfyUI or Hugging Face layout, and the engine's importer takes
/// none of them for anything newer than SDXL.
///
/// A retrained copy keeps every tensor of the original at its size, and its values stay close to
/// the original's. So instead of a translation table per family, each tensor of the installed
/// standard part is paired with the tensor of the new file that resembles it most: sizes first,
/// then correlation over a few thousand points, trying the ways the engine stores weights
/// differently (transposed, or the rows of each attention head interleaved, which is how it
/// rotates positions in Qwen3). Every tensor must find its pair clearly, or nothing is written.
/// The copy is then written under the standard part's tensor names and in its storage (8-bit
/// stays 8-bit, never less), and a model can read it instead of the standard one, run by run
/// (`PartsOverride`).
enum ModelParts {
  enum Slot: String, Codable, CaseIterable {
    case autoencoder = "autoencoder"
    case textEncoder = "text_encoder"
    case clipEncoder = "clip_encoder"
    case t5Encoder = "t5_encoder"
    case imageEncoder = "image_encoder"

    /// In the PRO block.
    var title: String {
      switch self {
      case .autoencoder: return "VAE"
      case .textEncoder: return "текстовый кодировщик"
      case .clipEncoder: return "CLIP"
      case .t5Encoder: return "T5"
      case .imageEncoder: return "кодировщик картинок"
      }
    }

    /// In the model list.
    var badge: String {
      switch self {
      case .autoencoder: return "VAE"
      case .textEncoder: return "ENCODER"
      case .clipEncoder: return "CLIP"
      case .t5Encoder: return "T5"
      case .imageEncoder: return "IMAGE ENCODER"
      }
    }

    /// In the file name. Each is a word the model picker reads as "not a model", so even a
    /// file missing from the list is never offered as one.
    var fileWord: String {
      switch self {
      case .autoencoder: return "vae"
      case .textEncoder: return "encoder"
      case .clipEncoder: return "clip"
      case .t5Encoder: return "t5_encoder"
      case .imageEncoder: return "image_encoder"
      }
    }
  }

  /// One added part: what it is called, which slot it fills and which standard file it stands
  /// in for. A model can use it wherever its description names that standard file.
  struct Entry: Codable, Hashable {
    var name: String
    var slot: Slot
    var stock: String
  }

  enum Failure: Error {
    case unreadable
    /// No installed model names a standard part this file could be a copy of.
    case noStandard
    /// The closest standard part, and how many of its tensors found a clear pair.
    case mismatch(stock: String, matched: Int, total: Int)
    case noSpace(Double)
    case incomplete
  }

  // MARK: the list of added parts

  /// Kept beside the models. The engine reads only its own custom*.json and leaves it alone.
  static let listName = "lil-parts.json"

  static func entries(in dir: URL) -> [String: Entry] {
    guard let data = try? Data(contentsOf: dir.appendingPathComponent(listName)),
      let all = try? JSONDecoder().decode([String: Entry].self, from: data)
    else { return [:] }
    return all
  }

  static func remove(_ file: String, in dir: URL) {
    var all = entries(in: dir)
    guard all.removeValue(forKey: file) != nil else { return }
    try? save(all, in: dir)
  }

  private static func add(_ file: String, _ entry: Entry, in dir: URL) throws {
    var all = entries(in: dir)
    all[file] = entry
    try save(all, in: dir)
  }

  private static func save(_ all: [String: Entry], in dir: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(all).write(to: dir.appendingPathComponent(listName), options: .atomic)
  }

  // MARK: which standard parts are installed

  /// The parts a model's description names, slot by slot. A model naming its own file (Krea 2
  /// keeps its "CLIP" inside itself) has nothing there to swap.
  static func parts(of item: [String: Any]) -> [Slot: String] {
    let own = item["file"] as? String
    var out: [Slot: String] = [:]
    for slot in Slot.allCases {
      if let file = item[slot.rawValue] as? String, !file.isEmpty, file != own { out[slot] = file }
    }
    return out
  }

  struct Stock: Hashable {
    let file: String
    let slot: Slot
  }

  /// Standard parts of the models in the folder that are files of their own, in a stable order.
  static func stocks(models dir: URL, catalog: URL) -> [Stock] {
    let fm = FileManager.default
    func present(_ file: String) -> Bool { fm.fileExists(atPath: dir.appendingPathComponent(file).path) }
    var items: [[String: Any]] = []
    for url in [dir.appendingPathComponent("custom.json"), catalog] {
      guard let data = try? Data(contentsOf: url),
        let raw = try? JSONSerialization.jsonObject(with: data)
      else { continue }
      items += (raw as? [[String: Any]]) ?? ((raw as? [String: Any])?["models"] as? [[String: Any]]) ?? []
    }
    var seen = Set<Stock>()
    var out: [Stock] = []
    for item in items {
      guard let file = item["file"] as? String, present(file) else { continue }
      let named = parts(of: item)
      for slot in Slot.allCases {
        guard let part = named[slot], present(part) else { continue }
        let stock = Stock(file: part, slot: slot)
        if seen.insert(stock).inserted { out.append(stock) }
      }
    }
    return out
  }

  // MARK: naming

  private static let technicalTails = [
    "_fp8_e4m3fn_scaled", "_fp8_e5m2_scaled", "_fp8_scaled", "_fp8_e4m3fn", "_fp8_e5m2",
    "_scaled", "_fp8", "_fp16", "_bf16", "_fp32", "_f16", "_enc", "_encoder",
  ]

  private static func stem(of source: URL) -> String {
    var stem = source.deletingPathExtension().lastPathComponent
    var changed = true
    while changed {
      changed = false
      for tail in technicalTails where stem.lowercased().hasSuffix(tail) {
        stem = String(stem.dropLast(tail.count))
        changed = true
      }
    }
    return stem.isEmpty ? "part" : stem
  }

  /// "nsfw wan umt5-xxl" for nsfw_wan_umt5-xxl_fp8_scaled.safetensors.
  static func displayName(for source: URL) -> String {
    stem(of: source).replacingOccurrences(of: "_", with: " ")
      .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
  }

  /// The precision ending of the standard file, never below 8 bits: that is what gets written.
  private static func precisionTail(_ stock: String) -> String {
    let lower = stock.lowercased()
    if lower.hasSuffix("_f16.ckpt") { return "f16" }
    if lower.hasSuffix("x.ckpt") { return "i8x" }
    if lower.hasSuffix("p.ckpt") { return "q8p" }
    return "f16"
  }

  /// A file name nothing in the folder uses yet.
  static func fileName(for source: URL, slot: Slot, stock: String, in dir: URL) -> String {
    var cleaned = ""
    for character in stem(of: source) {
      cleaned +=
        character.isASCII && (character.isLetter || character.isNumber || character == ".")
        ? String(character) : "_"
    }
    let base = cleaned.lowercased()
    // "my_vae" stays "my_vae_f16", not "my_vae_vae_f16"
    let word = base.contains(slot.fileWord) ? "" : "_" + slot.fileWord
    let tail = word + "_" + precisionTail(stock) + ".ckpt"
    var copy = 1
    while true {
      let name = base + (copy > 1 ? "_\(copy)" : "") + tail
      let path = dir.appendingPathComponent(name).path
      if !FileManager.default.fileExists(atPath: path),
        !FileManager.default.fileExists(atPath: path + "-tensordata")
      {
        return name
      }
      copy += 1
    }
  }

  // MARK: the new file

  private static let readable: Set<String> = ["F16", "BF16", "F32", "F8_E4M3", "F8_E5M2"]

  private static func isSideNote(_ key: String) -> Bool {
    key == "scaled_fp8" || key.hasSuffix(".weight_scale") || key.hasSuffix(".scale_weight")
      || key.hasSuffix(".input_scale") || key.hasSuffix(".comfy_quant")
  }

  private enum Element {
    case f16, bf16, f32, f8
  }

  /// One tensor of the new file, ready to be read element by element.
  private struct SourceTensor {
    let name: String
    let entry: ScaledCheckpoint.Entry
    let element: Element
    let table: [Float]
    let scale: [Float]?
    let perRow: Int
    let squeezed: [Int]
  }

  /// The tensors of a safetensors file that hold weights, multipliers already looked up.
  private static func sourceTensors(_ url: URL, _ header: ScaledCheckpoint.Header) throws
    -> [SourceTensor]
  {
    let reader = try FileHandle(forReadingFrom: url)
    defer { try? reader.close() }
    var out: [SourceTensor] = []
    for name in header.entries.keys.sorted() where !isSideNote(name) {
      guard let entry = header.entries[name], readable.contains(entry.dtype), entry.count > 0
      else { continue }
      let element: Element
      switch entry.dtype {
      case "F16": element = .f16
      case "BF16": element = .bf16
      case "F32": element = .f32
      default: element = .f8
      }
      var scale: [Float]?
      if name.hasSuffix(".weight") {
        let base = String(name.dropLast(".weight".count))
        if let note = header.entries[base + ".weight_scale"] ?? header.entries[base + ".scale_weight"] {
          scale = try ScaledCheckpoint.readScale(reader, header, note)
        }
      }
      let rows = max(1, entry.shape.first ?? 1)
      if let scale, scale.count != 1, scale.count != rows { continue }
      out.append(
        SourceTensor(
          name: name, entry: entry, element: element,
          table: element == .f8 ? ScaledCheckpoint.decodeTable(entry.dtype) : [],
          scale: scale, perRow: max(1, entry.count / rows), squeezed: entry.shape.filter { $0 != 1 }))
    }
    return out
  }

  /// Element `i` of a source tensor; `base` is the start of the mapped file's tensor data.
  @inline(__always)
  private static func value(_ t: SourceTensor, _ i: Int, _ base: UnsafeRawPointer) -> Float {
    let p = base + t.entry.start
    let raw: Float
    switch t.element {
    case .f16: raw = Float(p.loadUnaligned(fromByteOffset: i * 2, as: Float16.self))
    case .bf16: raw = Float(bitPattern: UInt32(p.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self)) << 16)
    case .f32: raw = p.loadUnaligned(fromByteOffset: i * 4, as: Float.self)
    case .f8: raw = t.table[Int(p.load(fromByteOffset: i, as: UInt8.self))]
    }
    guard let scale = t.scale else { return raw }
    return raw * (scale.count == 1 ? scale[0] : scale[i / t.perRow])
  }

  // MARK: the standard part

  private struct StockTensor {
    let key: String
    let shape: [Int]
    let format: TensorFormat
    let count: Int
    var rows: Int { max(1, shape.filter { $0 != 1 }.first ?? 1) }
    var columns: Int { count / rows }
    var squeezed: [Int] { shape.filter { $0 != 1 } }
  }

  private static func sidecar(_ path: String) -> String? {
    let data = path + "-tensordata"
    return FileManager.default.fileExists(atPath: data) ? data : nil
  }

  /// Names and sizes only; nothing is decoded.
  private static func stockTensors(_ path: String) -> [StockTensor]? {
    var out: [StockTensor]?
    DynamicGraph().openStore(path, flags: .readOnly, externalStore: sidecar(path)) { store in
      var list: [StockTensor] = []
      for key in store.keys.sorted() {
        guard let tensor = store.read(like: key) else { continue }
        let shape = Array(tensor.shape)
        guard !shape.isEmpty else { continue }
        list.append(
          StockTensor(key: key, shape: shape, format: tensor.format, count: shape.reduce(1, *)))
      }
      out = list
    }
    return out
  }

  /// Every stock tensor size has at least as many tensors of that size in the new file, and
  /// the new file is not much more than the part. A whole checkpoint that carries its own VAE
  /// passes the first test but never the second, so it is never mistaken for its VAE.
  private static func couldBeCopy(_ stock: [StockTensor], of source: [SourceTensor]) -> Bool {
    guard !stock.isEmpty else { return false }
    let stockTotal = stock.reduce(0) { $0 + $1.count }
    let sourceTotal = source.reduce(0) { $0 + $1.entry.count }
    // room for a language model's output layer or a vision tower the engine does not keep
    guard Double(sourceTotal) <= Double(stockTotal) * 1.35 else { return false }
    var available: [Int: Int] = [:]
    for t in source { available[t.entry.count, default: 0] += 1 }
    var needed: [Int: Int] = [:]
    for t in stock { needed[t.count, default: 0] += 1 }
    return needed.allSatisfy { available[$0.key, default: 0] >= $0.value }
  }

  /// Whether a dropped file could be a copy of a standard part installed here. Reads only the
  /// file's header and the parts' tensor sizes.
  static func looksLikePart(_ url: URL, models dir: URL, catalog: URL) -> Bool {
    guard url.pathExtension.lowercased() == "safetensors",
      let header = ScaledCheckpoint.header(of: url),
      let tensors = try? sourceTensors(url, header), !tensors.isEmpty
    else { return false }
    return stocks(models: dir, catalog: catalog).contains { stock in
      stockTensors(dir.appendingPathComponent(stock.file).path).map { couldBeCopy($0, of: tensors) }
        ?? false
    }
  }

  private static let decodable: DynamicGraph.Store.Codec = [
    .q8p, .q7p, .q6p, .q5p, .q4p, .i8x, .ezm7, .externalData(.mmap),
  ]

  // MARK: pairing

  private enum Transform: Equatable {
    case same
    case transposed
    /// Rows of each head of this size interleaved: the engine's half i of a pair is row 2i,
    /// the other half's row 2i + 1; Hugging Face keeps them k/2 apart.
    case rotary(Int)
    /// Both: a file that keeps its matrices the other way round and its heads unrotated.
    case rotaryTransposed(Int)
  }

  /// Where element `i` of the standard tensor sits in the new file's tensor.
  @inline(__always)
  private static func sourceIndex(_ i: Int, _ transform: Transform, rows: Int, columns: Int) -> Int {
    switch transform {
    case .same:
      return i
    case .transposed:
      return (i % columns) * rows + i / columns
    case .rotary(let k), .rotaryTransposed(let k):
      let row = i / columns
      let head = row / k
      let j = row % k
      let from = head * k + (j % 2 == 0 ? j / 2 : j / 2 + k / 2)
      if case .rotaryTransposed = transform { return (i % columns) * rows + from }
      return from * columns + i % columns
    }
  }

  private static func transforms(_ stock: StockTensor, _ source: SourceTensor) -> [Transform] {
    var out: [Transform] = []
    let s = stock.squeezed
    if source.squeezed == s {
      out.append(.same)
      for k in [64, 128, 256] where stock.rows >= k && stock.rows % k == 0 {
        out.append(.rotary(k))
      }
    }
    if s.count == 2, source.squeezed == [s[1], s[0]] {
      out.append(.transposed)
      for k in [64, 128, 256] where stock.rows >= k && stock.rows % k == 0 {
        out.append(.rotaryTransposed(k))
      }
    }
    return out
  }

  private static let samples = 4_096

  private static func positions(_ count: Int) -> [Int] {
    let n = min(count, samples)
    return (0..<n).map { Int(Int64($0) * Int64(count) / Int64(n)) }
  }

  private struct Fingerprint {
    let values: [Float]
    let mean: Double
    let spread: Double

    init(_ values: [Float]) {
      self.values = values
      let n = Double(max(1, values.count))
      let mean = values.reduce(0.0) { $0 + Double($1) } / n
      self.mean = mean
      spread = (values.reduce(0.0) { $0 + (Double($1) - mean) * (Double($1) - mean) }).squareRoot()
    }
  }

  /// Pearson correlation; two flat tensors count as a match only when they hold the same value.
  private static func score(_ a: Fingerprint, _ b: Fingerprint) -> Double {
    let flatA = a.spread <= 1e-9 * max(1, abs(a.mean))
    let flatB = b.spread <= 1e-9 * max(1, abs(b.mean))
    if flatA || flatB {
      return flatA && flatB && abs(a.mean - b.mean) <= 1e-3 * max(1, abs(a.mean)) ? 1 : 0
    }
    var sum = 0.0
    for i in 0..<min(a.values.count, b.values.count) {
      sum += (Double(a.values[i]) - a.mean) * (Double(b.values[i]) - b.mean)
    }
    return sum / (a.spread * b.spread)
  }

  private struct Pair {
    let source: Int
    let transform: Transform
    let score: Double
  }

  /// A clear pair is far above chance; a retrained copy scores 0.95 and up.
  private static let enough = 0.85

  /// Decodes the standard part once, tensor by tensor, and pairs each tensor with the new
  /// file's. Returns the pairing in the standard part's order (nil where a tensor found no
  /// clear pair), plus whether each stock tensor is stored at 32 bits.
  private static func pair(
    _ stock: [StockTensor], stockPath: String, _ source: [SourceTensor], base: UnsafeRawPointer,
    progress: (Double) -> Void, shouldStop: () -> Bool
  ) throws -> (pairs: [Pair?], float32: [Bool]) {
    var bySize: [Int: [Int]] = [:]
    for (index, t) in source.enumerated() { bySize[t.entry.count, default: []].append(index) }
    var candidates: [(stock: Int, pair: Pair)] = []
    var float32 = [Bool](repeating: false, count: stock.count)
    var cache: [String: Fingerprint] = [:]
    var failure: Error?
    let opened = DynamicGraph().openStore(stockPath, flags: .readOnly, externalStore: sidecar(stockPath)) {
      store in
      for (index, tensor) in stock.enumerated() {
        if shouldStop() {
          failure = CancellationError()
          return
        }
        guard let decoded = store.read(tensor.key, codec: decodable) else {
          failure = Failure.unreadable
          return
        }
        let points = positions(tensor.count)
        let values: [Float]
        switch decoded.dataType {
        case .Float32:
          float32[index] = true
          values = Tensor<Float>(from: decoded).withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Float.self)
            return points.map { p[$0] }
          }
        default:
          values = Tensor<Float16>(from: decoded).withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Float16.self)
            return points.map { Float(p[$0]) }
          }
        }
        let print = Fingerprint(values)
        for s in bySize[tensor.count] ?? [] {
          var best: Pair?
          for transform in transforms(tensor, source[s]) {
            let id = "\(s)|\(transform)|\(tensor.rows)|\(tensor.columns)"
            let theirs: Fingerprint
            if let known = cache[id] {
              theirs = known
            } else {
              theirs = Fingerprint(
                points.map {
                  value(source[s], sourceIndex($0, transform, rows: tensor.rows, columns: tensor.columns), base)
                })
              cache[id] = theirs
            }
            let r = score(print, theirs)
            if r > (best?.score ?? 0.5) { best = Pair(source: s, transform: transform, score: r) }
          }
          if let best { candidates.append((index, best)) }
        }
        progress(Double(index + 1) / Double(stock.count))
      }
    }
    if let failure { throw failure }
    guard case .success = opened else { throw Failure.unreadable }

    // strongest first, each tensor of either file used once
    var pairs = [Pair?](repeating: nil, count: stock.count)
    var used = Set<Int>()
    for candidate in candidates.sorted(by: { $0.pair.score > $1.pair.score })
    where candidate.pair.score >= enough && pairs[candidate.stock] == nil
      && !used.contains(candidate.pair.source)
    {
      pairs[candidate.stock] = candidate.pair
      used.insert(candidate.pair.source)
    }
    return (pairs, float32)
  }

  // MARK: writing

  /// The standard tensor's own storage, never below 8 bits. Over the database's limit for one
  /// value (1 GB) a tensor always goes to the weights file beside it.
  private static func codec(_ stock: DynamicGraph.Store.Codec?, bytes: Int) -> DynamicGraph.Store.Codec {
    var codec: DynamicGraph.Store.Codec = []
    if let stock {
      if stock.contains(.q8p) || stock.contains(.q7p) || stock.contains(.q6p) || stock.contains(.q5p)
        || stock.contains(.q4p)
      {
        codec = [.q8p]
      } else if stock.contains(.i8x) {
        codec = [.i8x]
      } else if stock.contains(.ezm7) {
        codec = [.ezm7]
      }
      if stock.contains(.externalData) { codec.insert(.externalData) }
    }
    if bytes > 900_000_000 { codec.insert(.externalData) }
    return codec
  }

  private static func write(
    _ stock: [StockTensor], stockPath: String, pairs: [Pair], float32: [Bool],
    _ source: [SourceTensor], base: UnsafeRawPointer, to output: URL,
    progress: (Double) -> Void, shouldStop: () -> Bool
  ) throws {
    var codecs: [String: DynamicGraph.Store.Codec] = [:]
    DynamicGraph().openStore(stockPath, flags: .readOnly, externalStore: sidecar(stockPath)) { store in
      for t in stock { codecs[t.key] = store.codec(for: t.key) }
    }
    let external = output.path + "-tensordata"
    let total = max(1, stock.reduce(0) { $0 + $1.count })
    var done = 0
    let graph = DynamicGraph()
    let opened = try graph.openStore(output.path, externalStore: external) { store in
      try store.withTransaction {
        for (index, t) in stock.enumerated() {
          if shouldStop() { throw CancellationError() }
          let pair = pairs[index]
          let s = source[pair.source]
          let rows = t.rows
          let columns = t.columns
          if float32[index] {
            var tensor = Tensor<Float>(.CPU, format: t.format, shape: TensorShape(t.shape))
            tensor.withUnsafeMutableBytes { raw in
              let out = raw.bindMemory(to: Float.self)
              for i in 0..<t.count {
                out[i] = value(s, sourceIndex(i, pair.transform, rows: rows, columns: columns), base)
              }
            }
            try store.write(t.key, tensor: tensor, strict: true, codec: codec(codecs[t.key], bytes: t.count * 4))
          } else {
            var tensor = Tensor<Float16>(.CPU, format: t.format, shape: TensorShape(t.shape))
            tensor.withUnsafeMutableBytes { raw in
              if pair.transform == .same, s.element == .f16, s.scale == nil {
                raw.baseAddress!.copyMemory(from: base + s.entry.start, byteCount: t.count * 2)
              } else {
                let out = raw.bindMemory(to: Float16.self)
                for i in 0..<t.count {
                  out[i] = Float16(value(s, sourceIndex(i, pair.transform, rows: rows, columns: columns), base))
                }
              }
            }
            try store.write(t.key, tensor: tensor, strict: true, codec: codec(codecs[t.key], bytes: t.count * 2))
          }
          done += t.count
          progress(Double(done) / Double(total))
        }
      }
    }
    guard case .success = opened else { throw Failure.unreadable }

    // read back the names, the way the engine's importer checks its own output
    var found = 0
    graph.openStore(output.path, flags: .readOnly, externalStore: sidecar(output.path)) { store in
      let keys = Set(store.keys)
      found = stock.filter { keys.contains($0.key) }.count
    }
    guard found == stock.count else { throw Failure.incomplete }
  }

  // MARK: all together

  struct Outcome {
    let file: String
    let entry: Entry
  }

  private typealias Candidate = (stock: Stock, tensors: [StockTensor])

  /// Standard parts the new file could be a copy of, the closest in size first: a file with
  /// exactly the standard tensors and nothing more.
  private static func candidates(for tensors: [SourceTensor], in dir: URL, catalog: URL) -> [Candidate] {
    var out: [Candidate] = []
    for stock in stocks(models: dir, catalog: catalog) {
      guard let list = stockTensors(dir.appendingPathComponent(stock.file).path),
        couldBeCopy(list, of: tensors)
      else { continue }
      out.append((stock, list))
    }
    out.sort { abs($0.tensors.count - tensors.count) < abs($1.tensors.count - tensors.count) }
    return out
  }

  /// What pairing found for one standard part, without writing anything.
  struct Check {
    let stock: String
    let slot: Slot
    let matched: Int
    let total: Int
    /// How many tensors were read each way: "same", "transposed", "rotary(128)".
    let transforms: [String: Int]
    /// The lowest correlation among the pairs; a retrained copy stays well above 0.9.
    let weakest: Double
    /// The average one: of two parts that both pair fully, the copy is closer to its own.
    let mean: Double
  }

  /// Pairs the file with every standard part it could be a copy of and reports, writing
  /// nothing. Takes a minute or two: each candidate part is decoded once.
  static func check(_ source: URL, in dir: URL, catalog: URL, progress: (Double) -> Void) throws
    -> [Check]
  {
    guard source.pathExtension.lowercased() == "safetensors",
      let header = ScaledCheckpoint.header(of: source)
    else { throw Failure.unreadable }
    let tensors = try sourceTensors(source, header)
    let found = candidates(for: tensors, in: dir, catalog: catalog)
    let mapped = try Data(contentsOf: source, options: .alwaysMapped)
    return try mapped.withUnsafeBytes { raw -> [Check] in
      guard let start = raw.baseAddress else { throw Failure.unreadable }
      var out: [Check] = []
      for (number, candidate) in found.enumerated() {
        let result = try pair(
          candidate.tensors, stockPath: dir.appendingPathComponent(candidate.stock.file).path,
          tensors, base: start + header.dataStart,
          progress: { progress((Double(number) + $0) / Double(found.count)) }, shouldStop: { false })
        let pairs = result.pairs.compactMap { $0 }
        var transforms: [String: Int] = [:]
        for pair in pairs { transforms["\(pair.transform)", default: 0] += 1 }
        out.append(
          Check(
            stock: candidate.stock.file, slot: candidate.stock.slot, matched: pairs.count,
            total: candidate.tensors.count, transforms: transforms,
            weakest: pairs.map(\.score).min() ?? 0,
            mean: pairs.reduce(0) { $0 + $1.score } / Double(max(1, pairs.count))))
      }
      return out
    }
  }

  /// Finds which standard part `source` is a copy of, writes it into `dir` beside it and lists
  /// it. Nothing appears under a real name until the whole part is written and read back.
  static func install(
    _ source: URL, in dir: URL, catalog: URL, progress: (Double) -> Void,
    shouldStop: () -> Bool = { false }
  ) throws -> Outcome {
    guard source.pathExtension.lowercased() == "safetensors",
      let header = ScaledCheckpoint.header(of: source)
    else { throw Failure.unreadable }
    let tensors = try sourceTensors(source, header)
    let candidates = candidates(for: tensors, in: dir, catalog: catalog)
    guard !candidates.isEmpty else { throw Failure.noStandard }

    let needed = Int64(9) * 1_073_741_824
    if let free = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
      .volumeAvailableCapacityForImportantUsage, free < needed
    {
      throw Failure.noSpace(Double(needed) / 1_073_741_824)
    }

    let mapped = try Data(contentsOf: source, options: .alwaysMapped)
    return try mapped.withUnsafeBytes { raw -> Outcome in
      guard let start = raw.baseAddress else { throw Failure.unreadable }
      let base = start + header.dataStart
      // Every candidate is paired, and the closest copy wins: Qwen Image's VAE was retrained
      // from Wan's, so a copy of either pairs fully with both, only more tightly with its own.
      var best: (candidate: Candidate, pairs: [Pair], float32: [Bool], mean: Double)?
      var closest: (stock: String, matched: Int, total: Int)?
      // pairing is quick next to writing, which spends its time on the 8-bit palettes
      let share = 0.1 / Double(candidates.count)
      for (number, candidate) in candidates.enumerated() {
        let result = try pair(
          candidate.tensors, stockPath: dir.appendingPathComponent(candidate.stock.file).path,
          tensors, base: base, progress: { progress(share * (Double(number) + $0)) },
          shouldStop: shouldStop)
        let pairs = result.pairs.compactMap { $0 }
        guard pairs.count == candidate.tensors.count else {
          if pairs.count > closest?.matched ?? -1 {
            closest = (candidate.stock.file, pairs.count, candidate.tensors.count)
          }
          continue
        }
        let mean = pairs.reduce(0) { $0 + $1.score } / Double(max(1, pairs.count))
        if mean > best?.mean ?? -1 { best = (candidate, pairs, result.float32, mean) }
      }
      if let best {
        let candidate = best.candidate
        let pairs = best.pairs
        let stockPath = dir.appendingPathComponent(candidate.stock.file).path
        let file = fileName(
          for: source, slot: candidate.stock.slot, stock: candidate.stock.file, in: dir)
        let destination = dir.appendingPathComponent(file)
        let partial = URL(fileURLWithPath: destination.path + ".part")
        let partialData = partial.path + "-tensordata"
        let fm = FileManager.default
        func clean() {
          try? fm.removeItem(at: partial)
          try? fm.removeItem(atPath: partialData)
          try? fm.removeItem(atPath: partial.path + "-journal")
        }
        clean()
        do {
          try write(
            candidate.tensors, stockPath: stockPath, pairs: pairs, float32: best.float32, tensors,
            base: base, to: partial, progress: { progress(0.1 + 0.9 * $0) }, shouldStop: shouldStop)
          if shouldStop() { throw CancellationError() }
          // the weights file first: a .ckpt is never left without the data it points into
          if fm.fileExists(atPath: partialData) {
            let size = (try? fm.attributesOfItem(atPath: partialData)[.size] as? Int) ?? 0
            if size > 0 {
              try fm.moveItem(atPath: partialData, toPath: destination.path + "-tensordata")
            } else {
              try fm.removeItem(atPath: partialData)
            }
          }
          try fm.moveItem(at: partial, to: destination)
          let entry = Entry(
            name: displayName(for: source), slot: candidate.stock.slot, stock: candidate.stock.file)
          try add(file, entry, in: dir)
          return Outcome(file: file, entry: entry)
        } catch {
          clean()
          throw error
        }
      }
      if let closest {
        throw Failure.mismatch(stock: closest.stock, matched: closest.matched, total: closest.total)
      }
      throw Failure.noStandard
    }
  }
}
