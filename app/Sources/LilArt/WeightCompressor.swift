import Foundation
import NNC

/// How far a model is squeezed: most layers at `bits`, the ones that matter most at
/// `importantBits`. The important ones are the modulation (what turns the step and the prompt
/// into scale and shift for every block) and the first and last few blocks, where errors do the
/// most harm; that is how GGUF's mixed "K_M" files and Draw Things' own quantizer treat them.
/// Embeddings and the final projection always stay at 16 bits.
struct CompressionPlan: Codable, Hashable {
  var bits = 8
  var importantBits = 8
  var edgeBlocks = 1
  var raiseModulation = true

  static let eightBit = CompressionPlan(bits: 8, importantBits: 8, edgeBlocks: 0)

  static let presets: [(name: String, hint: String, plan: CompressionPlan)] = [
    ("8 бит", "почти без потерь, вдвое меньше 16-битной", .eightBit),
    ("6 бит · важное 8", "на глаз от 8 бит не отличить", .init(bits: 6, importantBits: 8, edgeBlocks: 1)),
    ("5 бит · важное 8", "чуть мягче мелкие детали", .init(bits: 5, importantBits: 8, edgeBlocks: 2)),
    ("4 бита · важное 8", "в 3.5 раза меньше 16-битной, детали беднее", .init(bits: 4, importantBits: 8, edgeBlocks: 2)),
    ("4 бита · важное 6", "ещё меньше, чуть больше потерь", .init(bits: 4, importantBits: 6, edgeBlocks: 2)),
    ("3 бита · важное 6", "только чтобы влезло в память", .init(bits: 3, importantBits: 6, edgeBlocks: 2)),
  ]

  var label: String {
    bits == importantBits || (!raiseModulation && edgeBlocks == 0)
      ? "\(bits) бит" : "\(bits) бит · важное \(importantBits)"
  }
}

/// Rewrites a converted model's weights from 16 bits down to `plan`.
///
/// The importer always writes 16-bit weights. A download that was already 8-bit (fp8, int8)
/// therefore comes out twice its size, and the engine then needs twice the memory for no
/// gain. Below 8 bits the newer models go to the engine's packed "k" formats (the catalog's
/// "_i6x" and "_i4x" files), which keep a scale per 32 numbers; the older UNet models go no
/// lower than the 6-bit palette, the least their reader takes.
///
/// Which tensors stay at full precision follows Draw Things' own quantizer
/// (Apps/ModelQuantizer), family by family.
enum WeightCompressor {
  enum Failure: Error {
    case unsupportedFamily(String)
    case openFailed
    case empty
    /// A tensor that could not be read; the original must never be replaced by a file without it.
    case incomplete
    case noSpace(Double)
  }

  static func canCompress(_ version: String) -> Bool { keepFull(for: version) != nil }

  /// The file name ending the engine's own releases use for the same kind of weights.
  static func suffix(for version: String, plan: CompressionPlan = .eightBit) -> String {
    if unetFamilies.contains(version) { return plan.bits >= 8 ? "_q8p.ckpt" : "_q6p.ckpt" }
    return "_i\(min(8, max(3, plan.bits)))x.ckpt"
  }

  static func isUNet(_ version: String) -> Bool { unetFamilies.contains(version) }

  private static let unetFamilies: Set<String> = [
    "v1", "v2", "ssd_1b", "svd_i2v", "sdxl_base_v0.9", "sdxl_refiner_v0.9",
    "wurstchen_v3.0_stage_b", "wurstchen_v3.0_stage_c", "kandinsky2.1",
  ]

  /// Name fragments of the tensors each family keeps at 16 bits; nil for families it cannot do.
  private static func keepFull(for version: String) -> [String]? {
    switch version {
    case "v1", "v2", "ssd_1b", "svd_i2v", "sdxl_base_v0.9", "sdxl_refiner_v0.9",
      "wurstchen_v3.0_stage_b", "kandinsky2.1":
      return ["visual_proj", "encoder_hid_proj"]
    case "wurstchen_v3.0_stage_c":
      return ["text_emb", "effnet", "previewer"]
    case "pixart":
      return ["embedder", "shift_table", "t_block"]
    case "sd3", "sd3_large":
      return ["embedder", "pos_embed", "ada_ln"]
    case "auraflow":
      return ["embedder", "pos_embed", "register_tokens"]
    case "hunyuan_video":
      return ["embedder", "pos_embed", "-linear-", "refiner_"]
    case "cosmos2.5_2b":
      return ["embedder", "pos_embed", "-linear-", "_linear_"]
    case "z_image":
      return ["embedder", "pos_embed", "-linear_final-"]
    case "flux1", "wan_v2.1_1.3b", "wan_v2.1_14b", "wan_v2.2_5b", "hidream_i1", "hidream_o1",
      "qwen_image", "krea_2", "ernie_image", "seedvr2_3b", "seedvr2_7b", "flux2", "flux2_9b",
      "flux2_4b", "ideogram_4":
      return ["embedder", "pos_embed", "-linear-"]
    default:
      return nil
    }
  }

  /// The storage of one tensor under a plan. Packed k formats need rows in whole 256s; a matrix
  /// that is not stays at 8 bits rather than fail.
  private static func codec(bits: Int, unet: Bool, shape: [Int]) -> DynamicGraph.Store.Codec {
    let squeezed = shape.filter { $0 > 1 }
    guard squeezed.count > 1 else { return [.ezm7] }
    if unet || shape.count != 2 {
      // convolutions and the UNet families: palettes, never under 6 bits
      return bits >= 8 ? [.q8p, .ezm7] : [.q6p, .ezm7]
    }
    let columns = shape.last ?? 0
    guard bits < 8, columns % 256 == 0 else { return [.i8x] }
    switch bits {
    case 7, 6: return .i8x(.q6k)
    case 5: return .i8x(.q5k)
    case 4: return .i8x(.q4k)
    default: return .i8x(.q3k)
    }
  }

  /// Bits a number takes in each storage, packing overhead included.
  private static func bitsPerNumber(_ codec: DynamicGraph.Store.Codec, unet: Bool, bits: Int, shape: [Int]) -> Double {
    if codec.contains(.q8p) { return 8.1 }
    if codec.contains(.q6p) { return 6.1 }
    if codec == [.ezm7] { return 12 }
    if codec == .i8x(.q6k) { return 6.56 }
    if codec == .i8x(.q5k) { return 5.5 }
    if codec == .i8x(.q4k) { return 4.5 }
    if codec == .i8x(.q3k) { return 3.44 }
    return 8.05
  }

  /// "…-12-0]" gives 12: for a layer repeated in every block that is the block's number.
  private static func blockIndex(_ key: String) -> (layer: String, index: Int)? {
    guard let range = key.range(of: #"-(\d+)-\d+\]$"#, options: .regularExpression) else { return nil }
    let tail = key[range].dropFirst().split(separator: "-")
    guard let index = tail.first.flatMap({ Int($0) }) else { return nil }
    return (String(key[..<range.lowerBound]), index)
  }

  private static func isModulation(_ key: String) -> Bool {
    let lower = key.lowercased()
    return lower.contains("ada_ln") || lower.contains("adaln") || lower.contains("modulation")
  }

  /// Which keys get the important bits: modulation, and the first and last `edgeBlocks` of every
  /// layer that repeats through the blocks.
  private static func importantKeys(_ keys: [String], plan: CompressionPlan) -> Set<String> {
    var last: [String: Int] = [:]
    for key in keys {
      if let found = blockIndex(key) { last[found.layer] = max(last[found.layer] ?? 0, found.index) }
    }
    var out = Set<String>()
    for key in keys {
      if plan.raiseModulation, isModulation(key) {
        out.insert(key)
        continue
      }
      guard plan.edgeBlocks > 0, let found = blockIndex(key), let top = last[found.layer],
        top >= plan.edgeBlocks * 2
      else { continue }
      if found.index < plan.edgeBlocks || found.index > top - plan.edgeBlocks { out.insert(key) }
    }
    return out
  }

  private static let readable: DynamicGraph.Store.Codec = [
    .q8p, .q6p, .q5p, .q4p, .i8x, .ezm7, .externalData,
  ]

  /// What the file would weigh under a plan, from the tensors' sizes alone.
  static func estimate(input: String, version: String, plan: CompressionPlan) -> Int64? {
    guard let keep = keepFull(for: version) else { return nil }
    let unet = unetFamilies.contains(version)
    var total = 0.0
    var ok = false
    DynamicGraph().openStore(input, flags: .readOnly) { store in
      let keys = store.keys
      let important = importantKeys(keys, plan: plan)
      for key in keys {
        guard let tensor = store.read(like: key) else { continue }
        let shape = Array(tensor.shape)
        let count = Double(shape.reduce(1, *))
        if keep.contains(where: { key.contains($0) }) {
          total += count * 2
          continue
        }
        let bits = important.contains(key) ? plan.importantBits : plan.bits
        let codec = codec(bits: bits, unet: unet, shape: shape)
        total += count * bitsPerNumber(codec, unet: unet, bits: bits, shape: shape) / 8
      }
      ok = !keys.isEmpty
    }
    return ok ? Int64(total) : nil
  }

  static func compress(
    input: String, output: String, version: String, plan: CompressionPlan = .eightBit,
    progress: (Double) -> Void, shouldStop: () -> Bool = { false }
  ) throws {
    guard let keep = keepFull(for: version) else { throw Failure.unsupportedFamily(version) }
    // room is checked up front because a full disk would leave a truncated file that looks
    // finished
    let inputBytes =
      ((try? FileManager.default.attributesOfItem(atPath: input))?[.size] as? Int64) ?? 0
    let needed = (estimate(input: input, version: version, plan: plan) ?? inputBytes / 10 * 6)
      + 1_073_741_824
    let free = try? URL(fileURLWithPath: output).deletingLastPathComponent()
      .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
      .volumeAvailableCapacityForImportantUsage
    if let free, free < needed { throw Failure.noSpace(Double(needed) / 1_073_741_824) }
    // these families keep their norms losslessly packed rather than quantized
    let lightNorms = ["sd3", "sd3_large", "auraflow"].contains(version)
    let unet = unetFamilies.contains(version)
    try? FileManager.default.removeItem(atPath: output)

    let graph = DynamicGraph()
    var written = 0
    var totalKeys = 0
    let opened = try graph.openStore(input, flags: .readOnly) { store in
      let keys = store.keys
      guard !keys.isEmpty else { throw Failure.empty }
      totalKeys = keys.count
      let important = importantKeys(keys, plan: plan)
      let saved = try graph.openStore(output) { out in
        try out.withTransaction {
          for (index, key) in keys.enumerated() {
            if shouldStop() { throw CancellationError() }
            // Skipping a tensor would drop it from the copy that then replaces the original.
            guard let tensor = store.read(key, codec: readable) else {
              throw Failure.incomplete
            }
            if keep.contains(where: { key.contains($0) }) {
              out.write(key, tensor: tensor)
            } else {
              let full = Tensor<Float16>(from: tensor)
              let shape = Array(full.shape)
              if lightNorms && key.contains("norm") {
                out.write(key, tensor: full, codec: [.ezm7])
              } else {
                let bits = important.contains(key) ? plan.importantBits : plan.bits
                out.write(key, tensor: full, codec: codec(bits: bits, unet: unet, shape: shape))
              }
            }
            written += 1
            if index % 8 == 0 || index == keys.count - 1 {
              progress(Double(index + 1) / Double(keys.count))
            }
          }
        }
      }
      if case .failure = saved { throw Failure.openFailed }
    }
    if case .failure = opened { throw Failure.openFailed }
    if written == 0 { throw Failure.empty }
    if written != totalKeys { throw Failure.incomplete }
  }
}
