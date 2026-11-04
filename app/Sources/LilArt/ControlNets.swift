import Foundation
import MediaGenerationKit
import ModelZoo

/// One ControlNet (or adapter) a model of some family can use.
struct ControlNetItem: Identifiable, Hashable {
  let file: String
  let name: String
  let family: String
  /// What it reads, as the engine names it ("canny", "pose"); nil for the "union" kind that
  /// reads whatever it is told to.
  let hint: String?
  let union: Bool
  /// Every file it needs: itself, an image encoder, a preprocessor.
  let files: [String]
  var id: String { file }
}

/// What the edit tab needs to know about ControlNets: which exist for a model, which are on
/// disk, how to fetch the rest, and what picture each of them reads.
///
/// They come from two lists: the engine's built-in one (mostly SD 1.5) and the catalog's
/// controlnets.json (SDXL, FLUX.1). Newer families — Krea 2, Qwen Image, FLUX.2, Z-Image — have
/// none in either; for them the pictures-as-references of editing models do that job.
@MainActor
enum ControlNets {
  static var cacheFile: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("lil-art/cache/controlnets.json")
  }

  /// The engine's reference-picture adapters (IP-Adapter and kin) take the moodboard; the rest
  /// are ControlNets proper.
  private static let usable: Set<String> = [
    "controlnet", "controlnetunion", "controlnetlora", "t2iadapter", "ipadapterplus",
    "ipadapterfull",
  ]

  private static var remote: [ControlNetZoo.Specification] = loadCache()

  private static func loadCache() -> [ControlNetZoo.Specification] {
    guard let data = try? Data(contentsOf: cacheFile) else { return [] }
    return decode(data) ?? []
  }

  private static func decode(_ data: Data) -> [ControlNetZoo.Specification]? {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    struct Lenient: Decodable {
      let value: ControlNetZoo.Specification?
      init(from decoder: Decoder) throws { value = try? ControlNetZoo.Specification(from: decoder) }
    }
    return (try? decoder.decode([Lenient].self, from: data))?.compactMap(\.value)
  }

  /// Fetches the catalog's list once in a while; the built-in one needs nothing.
  static func refreshCatalog() async {
    let age = (try? cacheFile.resourceValues(forKeys: [.contentModificationDateKey]))?
      .contentModificationDate.map { Date().timeIntervalSince($0) } ?? .infinity
    guard age > 24 * 3600, let url = URL(string: "https://models.drawthings.ai/controlnets.json"),
      let (data, response) = try? await URLSession.shared.data(from: url),
      (response as? HTTPURLResponse)?.statusCode == 200, let list = decode(data), !list.isEmpty
    else { return }
    try? FileManager.default.createDirectory(
      at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: cacheFile, options: .atomic)
    remote = list
  }

  /// Everything a model of this family can use, built-in first.
  static func items(for family: String) -> [ControlNetItem] {
    var seen = Set<String>()
    var out: [ControlNetItem] = []
    for spec in ControlNetZoo.availableSpecifications + remote {
      guard spec.version.rawValue == family, spec.deprecated != true,
        usable.contains(spec.type.rawValue), seen.insert(spec.file).inserted
      else { continue }
      var files = [spec.file]
      if let encoder = spec.imageEncoder { files.append(encoder) }
      if let preprocessor = spec.preprocessor { files.append(preprocessor) }
      out.append(
        ControlNetItem(
          file: spec.file, name: spec.name, family: family, hint: spec.modifier?.rawValue,
          union: spec.type.rawValue == "controlnetunion", files: files))
    }
    return out
  }

  static func hasAny(for family: String) -> Bool { !items(for: family).isEmpty }

  /// The catalog's ControlNets are unknown to the engine until told: like a model's
  /// description, theirs travels with the request (`ImageGeneratorUtils.metadataOverride`).
  static func prime(_ files: [String]) {
    for spec in remote where files.contains(spec.file) {
      ControlNetZoo.overrideMapping[spec.file] = spec
    }
  }

  // MARK: what each one reads

  enum Input {
    /// The engine makes it from the picture being edited.
    case source
    /// From the extra pictures (moodboard).
    case references
    /// A ready picture of this hint kind, given by the person.
    case picture(String)
    /// A depth map: made by the engine from the picture if its depth model is on disk,
    /// otherwise a ready one is needed.
    case depth
  }

  /// The union kind reads any of these; the person picks one.
  static let unionHints = ["canny", "depth", "pose", "tile", "blur", "gray", "lowquality"]

  static func input(for hint: String) -> Input {
    switch hint {
    case "canny", "softedge", "mlsd", "tile", "blur", "gray", "lowquality", "inpaint", "ip2p":
      return .source
    case "shuffle": return .references
    case "depth": return .depth
    case "pose": return .picture("pose")
    case "scribble": return .picture("scribble")
    case "color": return .picture("color")
    default: return .picture("custom")
    }
  }

  static func label(for hint: String) -> String {
    switch hint {
    case "canny": return "контуры"
    case "depth": return "глубина"
    case "pose": return "поза"
    case "scribble": return "набросок"
    case "lineart": return "линии"
    case "softedge": return "мягкие края"
    case "normalbae": return "нормали"
    case "seg": return "сегменты"
    case "mlsd": return "прямые линии"
    case "tile": return "тайл (детали)"
    case "blur": return "из размытого"
    case "gray": return "раскрасить ч/б"
    case "lowquality": return "из плохого качества"
    case "inpaint": return "инпейнт"
    case "ip2p": return "инструкция"
    case "shuffle": return "стиль с картинки"
    case "color": return "цветовая карта"
    default: return hint
    }
  }

  /// Extra files some kinds need to make their input from the picture.
  static let depthModel = "depth_anything_v2.0_f16.ckpt"
  static let softEdgeModel = "hed_f16.ckpt"

  static func helpers(for hint: String, in dir: URL) -> [String] {
    switch hint {
    case "softedge": return [softEdgeModel]
    default: return []
    }
  }

  static func isOnDisk(_ file: String, in dir: URL) -> Bool {
    FileManager.default.fileExists(atPath: dir.appendingPathComponent(file).path)
  }

  // MARK: fetching

  /// Downloads one file from the engine's file server into the folder; it gets its real name
  /// only when whole.
  static func fetch(
    _ file: String, into dir: URL, progress: @escaping @MainActor (Double) -> Void
  ) async throws {
    let destination = dir.appendingPathComponent(file)
    guard !FileManager.default.fileExists(atPath: destination.path) else { return }
    guard let url = libnncURL(file) else { throw URLError(.badURL) }
    var observation: NSKeyValueObservation?
    let downloaded: URL = try await withCheckedThrowingContinuation { continuation in
      let task = URLSession.shared.downloadTask(with: url) { location, response, error in
        if let error {
          continuation.resume(throwing: error)
          return
        }
        guard let location, let http = response as? HTTPURLResponse,
          (200..<300).contains(http.statusCode)
        else {
          continuation.resume(throwing: URLError(.badServerResponse))
          return
        }
        // the system deletes its temporary file as soon as this handler returns
        let kept = dir.appendingPathComponent(file + ".part")
        do {
          try? FileManager.default.removeItem(at: kept)
          try FileManager.default.moveItem(at: location, to: kept)
          continuation.resume(returning: kept)
        } catch {
          continuation.resume(throwing: error)
        }
      }
      observation = task.progress.observe(\.fractionCompleted) { value, _ in
        let fraction = value.fractionCompleted
        Task { @MainActor in progress(fraction) }
      }
      task.resume()
    }
    observation?.invalidate()
    try FileManager.default.moveItem(at: downloaded, to: destination)
  }
}

/// One ControlNet chosen for the edit, with its settings.
struct ControlPick: Identifiable, Equatable {
  let id = UUID()
  var file: String
  var weight: Double = 1
  var start: Double = 0
  var end: Double = 1
  /// For the union kind: what it should read.
  var unionHint = "canny"
  /// A ready control picture, for the kinds that cannot make theirs from the edited one.
  var picture: Reference?

  static func == (a: ControlPick, b: ControlPick) -> Bool {
    a.id == b.id && a.file == b.file && a.weight == b.weight && a.start == b.start
      && a.end == b.end && a.unionHint == b.unionHint && a.picture?.url == b.picture?.url
  }
}
