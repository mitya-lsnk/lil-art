import Foundation
import ImageIO

/// Generation settings found somewhere else: in a picture's metadata (A1111, Forge, Civitai,
/// ComfyUI, Draw Things) or in the pictures people posted on Civitai for a model.
struct FoundSettings {
  var prompt: String?
  var negative: String?
  var steps: Int?
  var cfg: Double?
  /// As the other program wrote it: "DPM++ 2M Karras", "euler_ancestral".
  var sampler: String?
  var scheduler: String?
  var seed: UInt32?
  var width: Int?
  var height: Int?
  var model: String?
  var strength: Double?
  var clipSkip: Int?
  var shift: Double?
  /// Where it came from, for the summary.
  var origin = ""

  var isEmpty: Bool {
    prompt == nil && steps == nil && cfg == nil && sampler == nil && seed == nil && width == nil
  }
}

enum SettingsImport {
  // MARK: reading a picture

  static func read(_ url: URL) -> FoundSettings? {
    if let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.starts(with: pngSignature) {
      let texts = pngTexts(data)
      if let found = fromTexts(texts) { return found }
    }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    else { return nil }
    var texts: [String: String] = [:]
    if let png = props[kCGImagePropertyPNGDictionary] as? [CFString: Any] {
      if let c = png[kCGImagePropertyPNGComment] as? String { texts["Comment"] = c }
      if let d = png[kCGImagePropertyPNGDescription] as? String { texts["Description"] = d }
    }
    if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
      let comment = exif[kCGImagePropertyExifUserComment] as? String
    {
      texts["parameters"] = comment
    }
    if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
      let description = tiff[kCGImagePropertyTIFFImageDescription] as? String
    {
      texts["Description"] = texts["Description"] ?? description
    }
    return fromTexts(texts)
  }

  private static func fromTexts(_ texts: [String: String]) -> FoundSettings? {
    // Draw Things: a JSON comment with short keys
    if let comment = texts["Comment"], let found = fromDrawThings(comment), !found.isEmpty {
      return found
    }
    if let text = texts["parameters"] ?? texts["Description"], let found = fromA1111(text),
      !found.isEmpty
    {
      return found
    }
    if let prompt = texts["prompt"], let found = fromComfy(prompt), !found.isEmpty { return found }
    return nil
  }

  private static let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

  /// tEXt, zTXt and iTXt chunks: keyword → text. ImageIO shows only the standard keywords, and
  /// the ones that matter here ("parameters", "prompt") are not standard.
  static func pngTexts(_ data: Data) -> [String: String] {
    var out: [String: String] = [:]
    var offset = 8
    let bytes = [UInt8](data)
    while offset + 12 <= bytes.count {
      let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8
        | Int(bytes[offset + 3])
      let type = String(bytes: bytes[(offset + 4)..<(offset + 8)], encoding: .ascii) ?? ""
      let start = offset + 8
      let end = start + length
      guard length >= 0, end + 4 <= bytes.count else { break }
      let body = Array(bytes[start..<end])
      if type == "IEND" { break }
      if let zero = body.firstIndex(of: 0) {
        let key = String(bytes: body[0..<zero], encoding: .isoLatin1) ?? ""
        switch type {
        case "tEXt":
          // the format says Latin-1, but plenty of tools put UTF-8 there
          let text = Array(body[(zero + 1)...])
          out[key] = String(bytes: text, encoding: .utf8) ?? String(bytes: text, encoding: .isoLatin1)
        case "zTXt":
          if zero + 2 <= body.count, let text = inflate(Array(body[(zero + 2)...])) {
            out[key] = String(data: text, encoding: .isoLatin1)
          }
        case "iTXt":
          // keyword \0 flag method language \0 translated \0 text
          guard zero + 3 <= body.count else { break }
          let compressed = body[zero + 1] == 1
          var rest = Array(body[(zero + 3)...])
          guard let l = rest.firstIndex(of: 0) else { break }
          rest = Array(rest[(l + 1)...])
          guard let t = rest.firstIndex(of: 0) else { break }
          let raw = Array(rest[(t + 1)...])
          let text = compressed ? inflate(raw) : Data(raw)
          out[key] = text.flatMap { String(data: $0, encoding: .utf8) }
        default:
          break
        }
      }
      offset = end + 4
    }
    return out
  }

  /// zlib data (two header bytes, deflate, checksum) to plain bytes.
  private static func inflate(_ bytes: [UInt8]) -> Data? {
    guard bytes.count > 6 else { return nil }
    let deflate = Data(bytes[2..<(bytes.count - 4)])
    return try? (deflate as NSData).decompressed(using: .zlib) as Data
  }

  /// "prompt\nNegative prompt: …\nSteps: 30, Sampler: DPM++ 2M Karras, CFG scale: 7, …"
  static func fromA1111(_ text: String) -> FoundSettings? {
    let lines = text.components(separatedBy: "\n")
    guard let paramsIndex = lines.lastIndex(where: { $0.hasPrefix("Steps:") }) else { return nil }
    var found = FoundSettings(origin: "A1111")
    var prompt: [String] = []
    var negative: [String] = []
    var inNegative = false
    for line in lines[..<paramsIndex] {
      if line.hasPrefix("Negative prompt:") {
        inNegative = true
        negative.append(String(line.dropFirst("Negative prompt:".count)).trimmingCharacters(in: .whitespaces))
      } else if inNegative {
        negative.append(line)
      } else {
        prompt.append(line)
      }
    }
    found.prompt = prompt.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    let neg = negative.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    found.negative = neg.isEmpty ? nil : neg
    let fields = parseFields(lines[paramsIndex...].joined(separator: "\n"))
    found.steps = fields["Steps"].flatMap { Int($0) }
    found.cfg = fields["CFG scale"].flatMap { Double($0) }
    found.sampler = fields["Sampler"]
    found.scheduler = fields["Schedule type"]
    found.seed = fields["Seed"].flatMap { UInt32($0) ?? UInt32(exactly: (Double($0) ?? -1)) }
    if let size = fields["Size"]?.split(separator: "x"), size.count == 2 {
      found.width = Int(size[0])
      found.height = Int(size[1])
    }
    found.model = fields["Model"]
    found.strength = fields["Denoising strength"].flatMap { Double($0) }
    found.clipSkip = fields["Clip skip"].flatMap { Int($0) }
    found.shift = fields["Shift"].flatMap { Double($0) }
    if found.prompt?.isEmpty == true { found.prompt = nil }
    return found
  }

  /// "Key: value, Key: "quoted, value", …" into a dictionary.
  private static func parseFields(_ text: String) -> [String: String] {
    var out: [String: String] = [:]
    var key = ""
    var value = ""
    var readingKey = true
    var quoted = false
    func flush() {
      let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
      if !k.isEmpty { out[k] = value.trimmingCharacters(in: .whitespacesAndNewlines) }
      key = ""
      value = ""
      readingKey = true
    }
    for character in text {
      if readingKey {
        if character == ":" { readingKey = false } else { key.append(character) }
      } else if character == "\"" {
        quoted.toggle()
      } else if character == ",", !quoted {
        flush()
      } else {
        value.append(character)
      }
    }
    flush()
    return out
  }

  /// Draw Things' own comment: {"c": prompt, "uc": negative, "steps", "sampler", "scale", …}.
  static func fromDrawThings(_ text: String) -> FoundSettings? {
    guard let data = text.data(using: .utf8),
      let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      json["c"] != nil || json["steps"] != nil
    else { return nil }
    var found = FoundSettings(origin: "Draw Things")
    found.prompt = json["c"] as? String
    found.negative = (json["uc"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    found.steps = (json["steps"] as? NSNumber)?.intValue
    found.cfg = (json["scale"] as? NSNumber)?.doubleValue
    found.sampler = json["sampler"] as? String
    found.seed = (json["seed"] as? NSNumber).map { UInt32(truncatingIfNeeded: $0.int64Value) }
    if let size = (json["size"] as? String)?.split(separator: "x"), size.count == 2 {
      found.width = Int(size[0])
      found.height = Int(size[1])
    }
    found.model = json["model"] as? String
    found.strength = (json["strength"] as? NSNumber)?.doubleValue
    found.shift = (json["shift"] as? NSNumber)?.doubleValue
    found.clipSkip = (json["clip_skip"] as? NSNumber)?.intValue
    return found
  }

  /// ComfyUI's "prompt" chunk: the node graph as it ran. The sampler node gives the numbers,
  /// and the text nodes wired into its positive and negative inputs give the prompts.
  static func fromComfy(_ text: String) -> FoundSettings? {
    guard let data = text.data(using: .utf8),
      let graph = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return nil }
    let nodes = graph.compactMapValues { $0 as? [String: Any] }
    guard
      let sampler = nodes.values.first(where: {
        (($0["class_type"] as? String) ?? "").lowercased().contains("ksampler")
      }),
      let inputs = sampler["inputs"] as? [String: Any]
    else { return nil }
    func number(_ key: String) -> Double? { (inputs[key] as? NSNumber)?.doubleValue }
    func promptText(of link: Any?) -> String? {
      guard let pair = link as? [Any], let id = pair.first.map({ "\($0)" }), let node = nodes[id],
        let nodeInputs = node["inputs"] as? [String: Any]
      else { return nil }
      if let t = nodeInputs["text"] as? String { return t }
      if let t = nodeInputs["text_g"] as? String { return t }
      // a conditioning passed through another node: follow its first conditioning input
      for (_, value) in nodeInputs where value is [Any] {
        if let t = promptText(of: value) { return t }
      }
      return nil
    }
    var found = FoundSettings(origin: "ComfyUI")
    found.steps = number("steps").map { Int($0) }
    found.cfg = number("cfg")
    found.sampler = inputs["sampler_name"] as? String
    found.scheduler = inputs["scheduler"] as? String
    found.seed = (number("seed") ?? number("noise_seed")).map { UInt32(truncatingIfNeeded: Int64($0)) }
    found.strength = number("denoise")
    found.prompt = promptText(of: inputs["positive"])
    found.negative = promptText(of: inputs["negative"]).flatMap { $0.isEmpty ? nil : $0 }
    for node in nodes.values {
      let type = (node["class_type"] as? String) ?? ""
      let nodeInputs = node["inputs"] as? [String: Any] ?? [:]
      if type.contains("EmptyLatentImage") || type.contains("EmptySD3LatentImage") {
        found.width = (nodeInputs["width"] as? NSNumber)?.intValue
        found.height = (nodeInputs["height"] as? NSNumber)?.intValue
      }
      if type.contains("CheckpointLoader") || type.contains("UNETLoader") {
        found.model = (nodeInputs["ckpt_name"] ?? nodeInputs["unet_name"]) as? String
      }
      if type.contains("ModelSamplingAuraFlow") || type.contains("ModelSamplingSD3") {
        found.shift = (nodeInputs["shift"] as? NSNumber)?.doubleValue
      }
    }
    return found
  }

  // MARK: Civitai

  struct CivitaiModel: Identifiable {
    let id: Int
    let name: String
    let type: String
    let versions: [Version]

    struct Version: Identifiable {
      let id: Int
      let name: String
      let baseModel: String
      let description: String
    }
  }

  /// The settings people actually used, from the pictures posted for one model version.
  struct CivitaiStats {
    var samples = 0
    var samplers: [(name: String, count: Int)] = []
    var steps: [Int] = []
    var cfgs: [Double] = []
    var sizes: [(size: String, count: Int)] = []
    var clipSkips: [Int] = []
    var example: FoundSettings?

    static func median<T: Comparable>(_ values: [T]) -> T? {
      values.isEmpty ? nil : values.sorted()[values.count / 2]
    }
  }

  static func civitaiSearch(_ query: String) async throws -> [CivitaiModel] {
    var components = URLComponents(string: "https://civitai.com/api/v1/models")!
    components.queryItems = [
      .init(name: "query", value: query), .init(name: "limit", value: "12"),
      .init(name: "types", value: "Checkpoint"),
    ]
    let json = try await fetchJSON(components.url!)
    let items = (json["items"] as? [[String: Any]]) ?? []
    return items.compactMap { item in
      guard let id = item["id"] as? Int, let name = item["name"] as? String else { return nil }
      let versions = ((item["modelVersions"] as? [[String: Any]]) ?? []).compactMap { v -> CivitaiModel.Version? in
        guard let vid = v["id"] as? Int else { return nil }
        return .init(
          id: vid, name: (v["name"] as? String) ?? "", baseModel: (v["baseModel"] as? String) ?? "",
          description: plainText((v["description"] as? String) ?? ""))
      }
      return CivitaiModel(id: id, name: name, type: (item["type"] as? String) ?? "", versions: versions)
    }
  }

  static func civitaiStats(version: Int) async throws -> CivitaiStats {
    var components = URLComponents(string: "https://civitai.com/api/v1/images")!
    components.queryItems = [
      .init(name: "modelVersionId", value: String(version)), .init(name: "limit", value: "100"),
      .init(name: "sort", value: "Most Reactions"),
      // without it the API leaves out every picture's settings
      .init(name: "withMeta", value: "true"),
    ]
    let json = try await fetchJSON(components.url!)
    let items = (json["items"] as? [[String: Any]]) ?? []
    var stats = CivitaiStats()
    var samplers: [String: Int] = [:]
    var sizes: [String: Int] = [:]
    for item in items {
      guard let meta = civitaiMeta(item) else { continue }
      stats.samples += 1
      if let s = meta["sampler"] as? String { samplers[s, default: 0] += 1 }
      if let st = (meta["steps"] as? NSNumber)?.intValue { stats.steps.append(st) }
      if let c = (meta["cfgScale"] as? NSNumber)?.doubleValue { stats.cfgs.append(c) }
      if let z = meta["Size"] as? String { sizes[z, default: 0] += 1 }
      if let cs = (meta["clipSkip"] as? NSNumber)?.intValue ?? (meta["Clip skip"] as? String).flatMap({ Int($0) }) {
        stats.clipSkips.append(cs)
      }
      if stats.example == nil { stats.example = fromCivitaiMeta(meta) }
    }
    stats.samplers = samplers.map { ($0.key, $0.value) }.sorted { $0.count > $1.count }
    stats.sizes = sizes.map { ($0.key, $0.value) }.sorted { $0.count > $1.count }
    return stats
  }

  /// A picture posted on Civitai, by its number: its page or its file address carries it.
  static func civitaiImageID(_ url: URL) -> Int? {
    let host = url.host?.lowercased() ?? ""
    guard host.contains("civitai") else { return nil }
    if let range = url.path.range(of: #"/images/(\d+)"#, options: .regularExpression) {
      return Int(url.path[range].split(separator: "/").last ?? "")
    }
    // image.civitai.com/…/width=450/123456.jpeg
    let last = url.deletingPathExtension().lastPathComponent
    return Int(last)
  }

  static func civitaiImage(_ id: Int) async throws -> FoundSettings? {
    var components = URLComponents(string: "https://civitai.com/api/v1/images")!
    components.queryItems = [
      .init(name: "imageId", value: String(id)), .init(name: "withMeta", value: "true"),
    ]
    let json = try await fetchJSON(components.url!)
    guard let item = (json["items"] as? [[String: Any]])?.first, let meta = civitaiMeta(item)
    else { return nil }
    return fromCivitaiMeta(meta)
  }

  /// A picture's settings: right in "meta" in a model's list, one level deeper ("meta.meta")
  /// when the picture is asked for by its number.
  private static func civitaiMeta(_ item: [String: Any]) -> [String: Any]? {
    guard let meta = item["meta"] as? [String: Any] else { return nil }
    let inner = (meta["meta"] as? [String: Any]) ?? meta
    return inner["prompt"] != nil || inner["steps"] != nil || inner["sampler"] != nil ? inner : nil
  }

  private static func fromCivitaiMeta(_ meta: [String: Any]) -> FoundSettings {
    var found = FoundSettings(origin: "Civitai")
    found.prompt = meta["prompt"] as? String
    found.negative = meta["negativePrompt"] as? String
    found.steps = (meta["steps"] as? NSNumber)?.intValue
    found.cfg = (meta["cfgScale"] as? NSNumber)?.doubleValue
    found.sampler = meta["sampler"] as? String
    found.scheduler = meta["scheduler"] as? String
    found.seed = (meta["seed"] as? NSNumber).map { UInt32(truncatingIfNeeded: $0.int64Value) }
    if let size = (meta["Size"] as? String)?.split(separator: "x"), size.count == 2 {
      found.width = Int(size[0])
      found.height = Int(size[1])
    }
    found.model = meta["Model"] as? String
    found.clipSkip = (meta["clipSkip"] as? NSNumber)?.intValue
    found.strength = (meta["Denoising strength"] as? String).flatMap { Double($0) }
    return found
  }

  private static func fetchJSON(_ url: URL) async throws -> [String: Any] {
    var request = URLRequest(url: url, timeoutInterval: 20)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw URLError(.badServerResponse)
    }
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
  }

  /// Model descriptions on Civitai are HTML; the settings advice in them is what matters.
  private static func plainText(_ html: String) -> String {
    var text = html.replacingOccurrences(of: "<br>", with: "\n")
      .replacingOccurrences(of: "</p>", with: "\n").replacingOccurrences(of: "</li>", with: "\n")
    text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    for (entity, char) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'")] {
      text = text.replacingOccurrences(of: entity, with: char)
    }
    return text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
