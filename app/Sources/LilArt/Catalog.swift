import AppKit
import Foundation
import MediaGenerationKit
import SwiftUI
import UniformTypeIdentifiers

/// The engine ships a catalog of ready-made models and downloads them itself, exactly the
/// way the Draw Things app does. This is the browser over it.
/// What a model is actually for. The catalog does not say it outright, so it is derived:
/// a frame rate means video, an editing modifier means the model reworks a picture you give
/// it, everything else paints from text alone.
enum ModelKind: String, CaseIterable, Hashable {
  case textToImage, imageToImage, textToVideo, imageToVideo

  var label: String {
    switch self {
    case .textToImage: return "текст → изображение"
    case .imageToImage: return "изображение → изображение"
    case .textToVideo: return "текст → видео"
    case .imageToVideo: return "изображение → видео"
    }
  }

  static func of(name: String, modifier: String?, isVideo: Bool) -> ModelKind {
    let n = name.lowercased()
    let m = (modifier ?? "none").lowercased()
    let fromImage =
      ["kontext", "kontext_kv", "qwenimage_edit_plus", "editing", "inpainting", "ref2va", "fl2va"]
      .contains(m) || n.contains("i2v") || n.contains("edit") || n.contains("inp")
    if isVideo { return fromImage ? .imageToVideo : .textToVideo }
    return fromImage ? .imageToImage : .textToImage
  }
}

struct CatalogEntry: Identifiable, Hashable {
  var id: String { file }
  let file: String
  let name: String
  let note: String
  let family: String
  let kind: ModelKind
  var downloaded: Bool
  var bytes: Int64?
  /// Files this model cannot work without: the text encoder and the picture decoder.
  let companions: [String]
  /// The built-in engine does not know this family; only the external one can run it.
  let needsExternalEngine: Bool

  var sizeLabel: String {
    guard let bytes else { return "" }
    return String(format: "%.1f ГБ", Double(bytes) / 1_073_741_824)
  }
}

@available(macOS 26, *)
@MainActor
final class Catalog: ObservableObject {
  @Published var all: [CatalogEntry] = []
  @Published var query = ""
  @Published var family: String?
  @Published var kind: ModelKind?
  /// Set by the video tab when it sends someone here to fetch their first video model.
  @Published var videoOnly = false
  @Published var loading = false
  @Published var downloading: String?
  @Published var progressText = ""
  @Published var progress = 0.0
  @Published var note = ""

  private var sizeCache: [String: Int64] = [:]
  private var sizeInFlight: Set<String> = []

  var families: [String] { Array(Set(all.map(\.family))).sorted() }

  var filtered: [CatalogEntry] {
    var list = all
    if videoOnly { list = list.filter { $0.kind == .textToVideo || $0.kind == .imageToVideo } }
    if let family { list = list.filter { $0.family == family } }
    if let kind { list = list.filter { $0.kind == kind } }
    let q = query.trimmingCharacters(in: .whitespaces).lowercased()
    if !q.isEmpty {
      list = list.filter {
        $0.name.lowercased().contains(q) || $0.file.lowercased().contains(q)
          || $0.note.lowercased().contains(q)
      }
    }
    return list.sorted {
      if $0.downloaded != $1.downloaded { return $0.downloaded }
      return $0.name < $1.name
    }
  }

  /// Two sources, on purpose. The engine's own list says what this build can actually run;
  /// the public catalog carries the fields the engine's type drops (the modifier and the
  /// frame rate) which is what the categories are built from. Anything the engine does not
  /// know about is marked as external-only, because its resolver fails on it with "could not
  /// resolve"; those are fetched straight off the file server instead.
  func load() async {
    loading = true
    note = ""
    let supported = await MediaGenerationEnvironment.default
      .downloadableModels(includeDownloaded: true, offline: false)
    let usable = Set(supported.map(\.file))
    let installed = Set(supported.filter(\.isDownloaded).map(\.file))
    // An empty answer means the engine could not be asked (offline, still starting), not that
    // it knows no family at all, so then nothing is marked as external-only.
    let engineListKnown = !usable.isEmpty

    var skipped = 0
    var entries: [CatalogEntry] = []
    if let url = URL(string: "https://models.drawthings.ai/models.json"),
      let (data, response) = try? await URLSession.shared.data(from: url),
      let list = CatalogCache.storeIfValid(data, response: response)
    {
      for m in list {
        guard let file = m["file"] as? String, let name = m["name"] as? String else { continue }
        let known = !engineListKnown || usable.contains(file)
        if !known { skipped += 1 }
        let family = (m["version"] as? String) ?? "?"
        // Not every video model carries a frame rate in the catalog (SVD and LTX do not),
        // so the family has the final word.
        let isVideo = m["frames_per_second"] != nil || VideoFamily.isVideo(family)
        let kind = ModelKind.of(name: name, modifier: m["modifier"] as? String, isVideo: isVideo)
        entries.append(
          CatalogEntry(
            file: file, name: name, note: (m["note"] as? String) ?? "", family: family,
            kind: kind, downloaded: installed.contains(file), bytes: sizeCache[file],
            companions: companionFiles(in: m, file: file), needsExternalEngine: !known))
      }
    }
    // If the public catalog is unreachable, fall back to the engine's own list.
    if entries.isEmpty {
      entries = supported.map {
        CatalogEntry(
          file: $0.file, name: $0.name, note: $0.description, family: $0.version ?? "?",
          kind: .textToImage, downloaded: $0.isDownloaded, bytes: sizeCache[$0.file],
          companions: [], needsExternalEngine: false)
      }
    }
    all = entries
    loading = false
    if all.isEmpty {
      note = "каталог не загрузился, проверьте сеть"
    } else if skipped > 0 {
      note = ""
    }
  }

  /// Fetches a model and its companions straight off the file server. True only when every
  /// file is in the models folder, so a model missing its text encoder is never reported done.
  private func directDownload(_ model: CatalogEntry, into modelsDir: URL) async -> Bool {
    let files = [model.file] + model.companions
    try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
    for (index, name) in files.enumerated() {
      let destination = modelsDir.appendingPathComponent(name)
      if FileManager.default.fileExists(atPath: destination.path) { continue }
      progressText = "качаю \(name) · \(index + 1) из \(files.count)"
      do {
        // with a live bar: one file is several gigabytes, and a bar stuck at 0 looks like a hang
        try await ControlNets.fetch(name, into: modelsDir) { [weak self] fraction in
          guard let self else { return }
          self.progress = (Double(index) + fraction) / Double(files.count)
        }
        progress = Double(index + 1) / Double(files.count)
      } catch {
        note = "\(name): \(Self.explain(error))"
        return false
      }
    }
    note = "\(model.name) готова"
    return true
  }

  private static func explain(_ error: Error) -> String {
    if let url = error as? URLError {
      switch url.code {
      case .notConnectedToInternet: return "нет интернета"
      case .timedOut: return "сервер не ответил вовремя"
      case .networkConnectionLost: return "связь оборвалась"
      case .badServerResponse: return "сервер ответил ошибкой — файла может не быть"
      default: return url.localizedDescription
      }
    }
    return error.localizedDescription
  }

  /// Asks the download host how big a file is, once per model, only for rows on screen.
  /// Straight from the file server, no resolver involved.
  func measure(_ file: String) {
    guard sizeCache[file] == nil, !sizeInFlight.contains(file) else { return }
    sizeInFlight.insert(file)
    Task {
      var bytes: Int64?
      if let url = libnncURL(file) {
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.httpMethod = "HEAD"
        // A 404 page has a Content-Length too; only a success says how big the model is.
        if let (_, response) = try? await URLSession.shared.data(for: request),
          let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
          let length = http.value(forHTTPHeaderField: "Content-Length"), let n = Int64(length)
        {
          bytes = n
        }
      }
      sizeInFlight.remove(file)
      guard let bytes else { return }
      sizeCache[file] = bytes
      if let i = all.firstIndex(where: { $0.file == file }) { all[i].bytes = bytes }
    }
  }

  func download(_ model: CatalogEntry, into modelsDir: URL, onDone: @escaping (Bool) -> Void) {
    guard downloading == nil else {
      onDone(false)
      return
    }
    // a disk that is not plugged in is not a reason to fetch the model again
    if let message = ModelsFolder.unavailableMessage(modelsDir) {
      note = message
      onDone(false)
      return
    }
    downloading = model.file
    progress = 0
    progressText = "начинаю"
    // the library reads this as the reason when the download fails, so no old text may be left
    note = ""

    // Families the built-in engine does not know cannot go through its resolver at all,
    // so those are fetched straight off the file server together with their companions.
    if model.needsExternalEngine {
      Task {
        let ok = await directDownload(model, into: modelsDir)
        if ok, let i = all.firstIndex(where: { $0.file == model.file }) {
          all[i].downloaded = true
        }
        onDone(ok)
        downloading = nil
        progressText = ""
        progress = 0
      }
      return
    }

    Task {
      do {
        _ = try await MediaGenerationEnvironment.default.ensure(model.file) { [weak self] state in
          if case let .downloading(file, index, total, written, expected) = state, expected > 0 {
            let fraction = Double(written) / Double(expected)
            Task { @MainActor in
              self?.progress = fraction
              self?.progressText = String(
                format: "%@ · %d из %d · %.1f / %.1f ГБ", file, index + 1, total,
                Double(written) / 1e9, Double(expected) / 1e9)
            }
          }
        }
        note = "\(model.name) готова"
        if let i = all.firstIndex(where: { $0.file == model.file }) { all[i].downloaded = true }
        onDone(true)
      } catch {
        // the kit's own downloader does not know every family the catalog lists (the newest
        // ones); the file server does, so the files are fetched from there instead
        let ok = await directDownload(model, into: modelsDir)
        if ok, let i = all.firstIndex(where: { $0.file == model.file }) { all[i].downloaded = true }
        if !ok { note = "не скачалось: " + note }
        onDone(ok)
      }
      downloading = nil
      progressText = ""
      progress = 0
    }
  }
}

/// A copy of the public model catalog kept on disk.
///
/// The kit's own lookup answers with a human label ("FLUX.2 4B") and knows nothing about
/// models fetched straight from the file server, while the raw family ("flux2_4b",
/// "krea_2") is exactly what the LoRA importer needs when it cannot recognise a file.
enum CatalogCache {
  static var file: URL {
    ProjectRoot.places.cache.appendingPathComponent("models.json")
  }

  private static let lock = NSLock()
  private static var map: [String: Entry]?

  struct Entry {
    let name: String
    let version: String
    /// "inpainting", "kontext" and friends: what the model wants on its input.
    let modifier: String
    let companions: [String]
    /// The swappable parts it names (VAE, text encoder, …), slot by slot.
    let parts: [ModelParts.Slot: String]
    /// The maker's own words on the model, where the settings it wants are often written.
    let note: String
  }

  static func store(_ data: Data) {
    try? FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: file, options: .atomic)
    lock.lock()
    map = nil
    lock.unlock()
    // The model library classifies files by this catalog, so it has to look again.
    NotificationCenter.default.post(name: .lilCatalogStored, object: nil)
  }

  /// The model dictionaries of a catalog body, or nil when the body is not a catalog.
  static func parse(_ data: Data) -> [[String: Any]]? {
    guard let raw = try? JSONSerialization.jsonObject(with: data) else { return nil }
    let list =
      (raw as? [[String: Any]]) ?? ((raw as? [String: Any])?["models"] as? [[String: Any]]) ?? []
    // A captive portal or an error page can still answer 200 with JSON; a real catalog
    // names the file of its models.
    return list.contains(where: { $0["file"] is String }) ? list : nil
  }

  /// Keeps a downloaded catalog only if the answer was a success and the body is a real
  /// model list, so a bad response never replaces the good copy on disk.
  static func storeIfValid(_ data: Data, response: URLResponse?) -> [[String: Any]]? {
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
      let list = parse(data)
    else { return nil }
    store(data)
    return list
  }

  /// Every catalog model by file name; empty if the catalog has never been fetched.
  static func entries() -> [String: Entry] {
    lock.lock()
    defer { lock.unlock() }
    if map == nil { map = load() }
    return map ?? [:]
  }

  /// Raw family for a model file, or nil if the catalog does not know it.
  static func rawFamily(of modelFile: String) -> String? {
    guard let version = entries()[modelFile]?.version, !version.isEmpty else { return nil }
    return version
  }

  private static func load() -> [String: Entry] {
    guard let data = try? Data(contentsOf: file),
      let raw = try? JSONSerialization.jsonObject(with: data)
    else { return [:] }
    let list =
      (raw as? [[String: Any]]) ?? ((raw as? [String: Any])?["models"] as? [[String: Any]]) ?? []
    var out: [String: Entry] = [:]
    for item in list {
      guard let file = item["file"] as? String else { continue }
      out[file] = Entry(
        name: (item["name"] as? String) ?? file, version: (item["version"] as? String) ?? "",
        modifier: (item["modifier"] as? String) ?? "",
        companions: companionFiles(in: item, file: file), parts: ModelParts.parts(of: item),
        note: (item["note"] as? String) ?? "")
    }
    return out
  }

  /// Fetches the catalog in the background when there is no copy yet or it is a day old.
  static func refreshIfStale() async {
    if let date = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate]
      as? Date, Date().timeIntervalSince(date) < 86_400
    {
      return
    }
    guard let url = URL(string: "https://models.drawthings.ai/models.json"),
      let (data, response) = try? await URLSession.shared.data(from: url)
    else { return }
    _ = storeIfValid(data, response: response)
  }
}

/// The engine answers "which family is this model" with a human label, built by
/// `ModelZoo.humanReadableNameForVersion`. This is that function turned inside out, so the
/// label can be taken back to the raw name the LoRA importer understands. Labels shared by
/// several families (Würstchen stages, SeedVR2 sizes) are left out on purpose.
enum FamilyNames {
  static let rawByLabel: [String: String] = [
    "Stable Diffusion v1": "v1",
    "Stable Diffusion v2": "v2",
    "Kandinsky v2.1": "kandinsky2.1",
    "Stable Diffusion XL Base": "sdxl_base_v0.9",
    "Stable Diffusion XL Refiner": "sdxl_refiner_v0.9",
    "Segmind Stable Diffusion XL 1B": "ssd_1b",
    "Stable Video Diffusion": "svd_i2v",
    "Stable Diffusion 3 Medium": "sd3",
    "Stable Diffusion 3 Large": "sd3_large",
    "PixArt Sigma": "pixart",
    "AuraFlow": "auraflow",
    "FLUX.1": "flux1",
    "Hunyuan Video": "hunyuan_video",
    "Wan v2.1 1.3B": "wan_v2.1_1.3b",
    "Wan v2.x 14B": "wan_v2.1_14b",
    "HiDream I1": "hidream_i1",
    "HiDream O1": "hidream_o1",
    "Qwen Image": "qwen_image",
    "Qwen Image 2.1": "qwen_image_2.1",
    "Wan v2.2 5B": "wan_v2.2_5b",
    "Z Image": "z_image",
    "ERNIE Image": "ernie_image",
    "FLUX.2": "flux2",
    "FLUX.2 9B": "flux2_9b",
    "FLUX.2 4B": "flux2_4b",
    "Cosmos 2.5 2B": "cosmos2.5_2b",
    "LTX-2": "ltx2",
    "LTX-2.3": "ltx2.3",
    "Ideogram 4": "ideogram_4",
    "Krea 2": "krea_2",
    "MiniMax H3": "minimax_h3",
    "LongCat-Video Avatar 1.5": "longcat_video_avatar_v1.5",
  ]

  static let labelByRaw: [String: String] = Dictionary(
    rawByLabel.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })

  /// The family as people call it, short enough for a badge.
  static func short(_ raw: String) -> String {
    switch raw {
    case "": return ""
    case "v1": return "SD 1.5"
    case "v2": return "SD 2"
    case "sdxl_base_v0.9": return "SDXL"
    case "sdxl_refiner_v0.9": return "SDXL Refiner"
    case "ssd_1b": return "SSD-1B"
    case "sd3": return "SD 3"
    case "sd3_large": return "SD 3 Large"
    default: return labelByRaw[raw] ?? raw
    }
  }
}

/// Builds a value of a String-backed enum from its raw value, given only its optional type.
/// The engine's model family type sits in a module the kit does not re-export.
func familyValue<T: RawRepresentable>(_: T?.Type, _ raw: String) -> T? where T.RawValue == String {
  T(rawValue: raw)
}

extension Notification.Name {
  /// Posted after a fresh, valid copy of the model catalog landed on disk.
  static let lilCatalogStored = Notification.Name("lil.catalogStored")
}

/// Every file a catalog item needs besides the model itself: encoders, the decoder and, for
/// multi-stage families, the other stages. Each key holds one name or a list of names.
/// Order is kept, empty names, the model itself and repeats are dropped.
func companionFiles(in item: [String: Any], file: String) -> [String] {
  let keys = [
    "text_encoder", "autoencoder", "clip_encoder", "t5_encoder",
    "additional_clip_encoders", "stage_models",
  ]
  var out: [String] = []
  for key in keys {
    let names: [String]
    if let one = item[key] as? String {
      names = [one]
    } else if let many = item[key] as? [Any] {
      names = many.compactMap { $0 as? String }
    } else {
      continue
    }
    for name in names where !name.isEmpty && name != file && !out.contains(name) {
      out.append(name)
    }
  }
  return out
}

/// Where the engine's file server keeps a model file. The name goes through percent-encoding
/// because a name with a space or other odd character would otherwise not form a URL at all.
func libnncURL(_ file: String) -> URL? {
  guard let encoded = file.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
    return nil
  }
  return URL(string: "https://static.libnnc.org/\(encoded)")
}
