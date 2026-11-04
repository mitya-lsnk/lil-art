import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

enum ModelRole: String {
  case checkpoint, lora, upscaler, part

  var badge: String {
    switch self {
    case .checkpoint: return "CHECKPOINT"
    case .lora: return "LORA"
    case .upscaler: return "UPSCALER"
    case .part: return "PART"
    }
  }

  var rank: Int {
    switch self {
    case .checkpoint: return 0
    case .lora: return 1
    case .upscaler: return 2
    case .part: return 3
    }
  }
}

/// Where a model's file is: in the folder, on an external disk behind a link, or behind a
/// link to a disk that is not plugged in.
enum ModelStorage: Hashable {
  case mac
  case external(String)
  case offline(String)

  var isOffline: Bool { if case .offline = self { return true } else { return false } }
  var isExternal: Bool { if case .mac = self { return false } else { return true } }
}

/// A model or LoRA that is ready: in the engine's own format, sitting in the models folder.
struct InstalledModel: Identifiable, Hashable {
  var id: String { file }
  let file: String
  let name: String
  /// Raw family ("krea_2"), empty when unknown.
  let family: String
  let role: ModelRole
  let bytes: Int64
  /// "8 бит", "16 бит" and so on, when the file name says it.
  let precision: String?
  /// Converted here from someone's file, rather than downloaded ready-made.
  let converted: Bool
  /// What the model wants on its input: "inpainting" on a video model means it animates
  /// a picture you give it, "" means it only listens to the prompt.
  var modifier: String = ""
  /// For a checkpoint: the swappable parts its description names (VAE, text encoder, …).
  var parts: [ModelParts.Slot: String] = [:]
  /// For a part added here: which slot it fills and which standard file it stands in for.
  var part: ModelParts.Entry? = nil
  var storage: ModelStorage = .mac

  /// Whether this picture model changes a picture by description (FLUX Kontext, FLUX.2,
  /// Qwen Image Edit and 2.1). The modifier says so when the catalog knows the file; the
  /// families that always edit cover the files it does not list, such as an older 8-bit copy.
  var canEdit: Bool {
    if ["kontext", "kontext_kv", "qwenimage_edit_plus", "qwenimage_edit_2511"].contains(modifier) {
      return true
    }
    guard modifier.isEmpty || modifier == "none" else { return false }
    if ["flux2", "flux2_4b", "flux2_9b", "qwen_image_2.1"].contains(family) { return true }
    let text = (file + " " + name).lowercased()
    return ["kontext", "qwen_image_edit", "image edit", "flux_2_", "flux.2", "qwen_image_2.1"]
      .contains { text.contains($0) }
  }

  /// Whether a starting picture is part of this model's job. The modifier is the honest
  /// answer, but it only arrives with the catalog; when that has not been fetched the
  /// name still gives it away, since makers put i2v and InP right in it.
  var takesImage: Bool {
    if ["inpainting", "editing", "kontext", "kontext_kv", "qwenimage_edit_plus",
      "qwenimage_edit_2511", "fl2va", "ref2va"].contains(modifier)
    {
      return true
    }
    // the importer writes "none" for anything it did not recognise, I2V included
    guard modifier.isEmpty || modifier == "none" else { return false }
    let text = (file + " " + name).lowercased()
    return ["i2v", "_inp", " inp", "img2vid", "image to video"].contains { text.contains($0) }
  }

  var sizeLabel: String {
    bytes >= 1_000_000_000
      ? String(format: "%.1f ГБ", Double(bytes) / 1_073_741_824)
      : String(format: "%.0f МБ", Double(bytes) / 1_048_576)
  }

  var familyLabel: String { FamilyNames.short(family) }

  /// A model converted here can be squeezed (again): from 16 bits, or from 8 further down.
  var canCompress: Bool {
    role == .checkpoint && converted && WeightCompressor.canCompress(family)
      && !file.contains("_i3x")
  }
}

enum ImportOrigin {
  case catalog, dropped, folder, library, fileServer
  /// Off to the external disk or back.
  case relocate
}

/// One file on its way into the library.
struct ImportJob: Identifiable {
  let id = UUID()
  let source: URL
  var name: String
  var role: ModelRole
  let origin: ImportOrigin
  var stage: JobStage = .waiting
  var progress = 0.0
  var stageStarted: Date?
  var result: String?
  var note: String?
  let cancel = CancelFlag()
  var catalogEntry: CatalogEntry?
  var compressVersion: String?
  var compressPlan: CompressionPlan = .eightBit
  /// The squeezed copy goes beside the original instead of replacing it.
  var keepOriginal = false
  /// For a move: the files, and which way.
  var moveFiles: [String] = []
  var moveBack = false

  var timeLeft: String? {
    guard stage.isRunning, progress > 0.03, let since = stageStarted else { return nil }
    let spent = Date().timeIntervalSince(since)
    guard spent > 20 else { return nil }
    let left = spent * (1 - progress) / progress
    return left < 60 ? "меньше минуты" : "осталось ~\(Int((left / 60).rounded(.up))) мин"
  }

  var failure: String? {
    if case .failed(let reason) = stage { return reason }
    return nil
  }
}

/// Everything about models in one place: what is installed, what is on its way in, and the
/// folder itself, which is watched, so a file put there through Finder is picked up without
/// anyone having to tell the app.
@available(macOS 26, *)
@MainActor
final class ModelLibrary: ObservableObject {
  @Published private(set) var installed: [InstalledModel] = []
  @Published private(set) var jobs: [ImportJob] = []
  @Published var query = ""
  @Published var roleFilter: ModelRole?
  /// How every newly imported model is squeezed; nil: as it came (an 8-bit download back to
  /// 8 bits, a 16-bit one left alone).
  @Published var importPlan: CompressionPlan? = {
    guard let data = UserDefaults.standard.data(forKey: "import.plan") else { return nil }
    return try? JSONDecoder().decode(CompressionPlan.self, from: data)
  }() {
    didSet {
      UserDefaults.standard.set(importPlan.flatMap { try? JSONEncoder().encode($0) }, forKey: "import.plan")
    }
  }
  @Published var catalogTab = false

  // filled in by the studio
  var engineHooks: () -> EngineHooks = { EngineHooks(pause: {}, resume: { _, _ in }, waitIdle: {}) }
  var engineTag: () -> String = { "" }
  var fallbackFamily: () -> String? = { nil }
  var onReady: (InstalledModel) -> Void = { _ in }
  var onListChanged: () -> Void = {}
  var onFailure: (ImportJob, String) -> Void = { _, _ in }
  weak var catalog: Catalog?

  let modelsDir: URL
  private var watcher: DispatchSourceFileSystemObject?
  private var rescanTask: Task<Void, Never>?
  private var running = false
  /// Files the converter is writing right now, kept out of the list until they are finished.
  private var hidden: Set<String> = []
  private let failedKey = "library.failed"
  private var catalogObserver: AnyCancellable?

  /// What the folder remembers between two looks at it (`FolderWatch`).
  private var folderWatch = FolderWatch()
  /// Final names (lowercased) of engine files being copied in, so two drops never pick one name.
  private var copying: Set<String> = []

  init(modelsDir: URL) {
    self.modelsDir = modelsDir
    rescan()
    watch()
    // a disk plugged in or out changes which moved models can run
    let center = NSWorkspace.shared.notificationCenter
    for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
      center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.scheduleRescan(after: 1) }
      }
    }
    // A fresh catalog changes what some files are (a stage model stops looking like a checkpoint).
    catalogObserver = NotificationCenter.default.publisher(for: .lilCatalogStored)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in MainActor.assumeIsolated { self?.rescan() } }
  }

  var activeJob: ImportJob? { jobs.first { $0.stage.isRunning } }
  /// Only what can run now: a model on an unplugged disk stays in the list, not in the pickers.
  var checkpoints: [InstalledModel] {
    installed.filter { $0.role == .checkpoint && !$0.storage.isOffline }
  }
  var loras: [InstalledModel] { installed.filter { $0.role == .lora && !$0.storage.isOffline } }
  var parts: [InstalledModel] { installed.filter { $0.role == .part && !$0.storage.isOffline } }

  /// An upscaler from the engine's file server. They are small, so no one is asked first.
  func fetch(_ upscaler: Upscalers.Model) {
    guard
      !jobs.contains(where: {
        $0.source.lastPathComponent == upscaler.file && $0.failure == nil
      })
    else { return }
    jobs.removeAll { $0.source.lastPathComponent == upscaler.file }
    jobs.append(
      ImportJob(
        source: modelsDir.appendingPathComponent(upscaler.file), name: upscaler.name,
        role: .upscaler, origin: .fileServer))
    runNext()
  }
  var preparing: [ImportJob] { jobs.filter { $0.role == .checkpoint && $0.failure == nil && $0.stage != .done } }
  var totalBytes: Int64 { installed.reduce(0) { $0 + $1.bytes } }

  var visible: [InstalledModel] {
    let q = query.trimmingCharacters(in: .whitespaces).lowercased()
    return installed.filter { model in
      (roleFilter == nil || model.role == roleFilter)
        && (q.isEmpty || model.name.lowercased().contains(q) || model.file.lowercased().contains(q)
          || model.familyLabel.lowercased().contains(q))
    }
  }

  // MARK: watching the folder

  private func watch() {
    let descriptor = open(modelsDir.path, O_EVTONLY)
    guard descriptor >= 0 else { return }
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
    source.setEventHandler { [weak self] in
      MainActor.assumeIsolated { self?.scheduleRescan(after: 0.8) }
    }
    source.setCancelHandler { close(descriptor) }
    source.resume()
    watcher = source
  }

  private func scheduleRescan(after seconds: Double) {
    rescanTask?.cancel()
    rescanTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
      guard !Task.isCancelled else { return }
      self?.rescan()
    }
  }

  func rescan() {
    let scan = scanFolder()
    reconcileFailedJobs(failed: failures(), incoming: scan.incoming)
    let found = scan.found.sorted {
      $0.role == $1.role ? $0.name.lowercased() < $1.name.lowercased() : $0.role.rank < $1.role.rank
    }
    if found != installed {
      installed = found
      onListChanged()
    }
    if scan.stillCopying { scheduleRescan(after: 2) }
  }

  /// One look at the folder: the models it holds, the files ready to import, and whether some
  /// file is still being copied in (so another look is due soon).
  private func scanFolder() -> (found: [InstalledModel], incoming: [URL], stillCopying: Bool) {
    let fm = FileManager.default
    let urls =
      (try? fm.contentsOfDirectory(
        at: modelsDir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]))
      ?? []
    let custom = CustomModels.entries(in: modelsDir)
    let parts = ModelParts.entries(in: modelsDir)
    let catalogEntries = CatalogCache.entries()
    var helpers = Set<String>()
    for entry in custom.values { helpers.formUnion(entry.companions) }
    for entry in catalogEntries.values { helpers.formUnion(entry.companions) }

    var found: [InstalledModel] = []
    var incoming: [URL] = []
    var stillCopying = false
    var present = Set<String>()
    for url in urls {
      let ext = url.pathExtension.lowercased()
      guard ["safetensors", "ckpt", "pt", "pth"].contains(ext) else { continue }
      present.insert(url.path)
      // a link means a model moved to an external disk: read what it points at
      let target = ModelMover.linkTarget(url)
      let link: FolderWatch.Link =
        target == nil ? .none : (fm.fileExists(atPath: target!.path) ? .reachable : .broken)
      let real = target ?? url
      let stamp = link == .broken ? nil : Self.stamp(of: real)
      let verdict = folderWatch.look(
        path: url.path, ext: ext, link: link, isEngineFormat: { ImportRunner.isEngineFormat(real) },
        stamp: stamp, now: Date())
      stillCopying = stillCopying || verdict.needsAnotherLook
      switch verdict {
      case .away:
        // its disk is unplugged: still listed, as away, but nothing reads it
        if ext == "ckpt",
          var model = classify(
            url, size: 0, custom: custom, parts: parts, catalog: catalogEntries, helpers: helpers)
        {
          model.storage = .offline(ModelsFolder.volumeName(of: target!) ?? "внешний диск")
          found.append(model)
        }
      case .model:
        if var model = classify(
          url, size: stamp?.size ?? 0, custom: custom, parts: parts, catalog: catalogEntries,
          helpers: helpers)
        {
          if let target { model.storage = .external(ModelsFolder.volumeName(of: target) ?? "диск") }
          found.append(model)
        }
      case .incoming:
        incoming.append(url)
      case .foreignLink, .emptyWaiting, .emptyGaveUp, .cancelledByUser, .growing:
        break
      }
    }
    folderWatch.forget(except: present)
    return (found, incoming, stillCopying)
  }

  /// Failed rows follow their files, and files ready to import are queued.
  private func reconcileFailedJobs(failed: [String: String], incoming: [URL]) {
    // A failed row goes away with its file when it is removed through Finder, and also when
    // the file changed after it failed (a copy that finished later): that one gets another go.
    jobs.removeAll { job in
      guard job.failure != nil, job.origin == .folder else { return false }
      if let stamp = Self.stamp(of: job.source),
        failed[Self.failureKey(job.source, stamp)] != nil
      {
        return false
      }
      forgetFailure(job.source)
      return true
    }
    for url in incoming where !jobs.contains(where: { $0.source.path == url.path }) {
      if let stamp = Self.stamp(of: url), let reason = failed[Self.failureKey(url, stamp)] {
        // it failed before; show why instead of failing again on every launch
        var job = ImportJob(
          source: url, name: Self.pretty(url.deletingPathExtension().lastPathComponent),
          role: Self.role(of: url), origin: .folder)
        job.stage = .failed(reason)
        jobs.append(job)
      } else {
        enqueue(url, origin: .folder)
      }
    }
  }

  private func classify(
    _ url: URL, size: Int64, custom: [String: CustomModels.Entry],
    parts: [String: ModelParts.Entry], catalog: [String: CatalogCache.Entry],
    helpers: Set<String>
  ) -> InstalledModel? {
    let file = url.lastPathComponent
    guard !hidden.contains(file) else { return nil }
    let lower = file.lowercased()
    let base = url.deletingPathExtension().lastPathComponent
    if let upscaler = Upscalers.model(file) {
      return InstalledModel(
        file: file, name: upscaler.name, family: "", role: .upscaler, bytes: size,
        precision: nil, converted: false)
    }
    if let entry = parts[file] {
      return InstalledModel(
        file: file, name: entry.name, family: "", role: .part, bytes: size,
        precision: Self.precision(lower), converted: true, part: entry)
    }
    if let entry = custom[file] {
      return InstalledModel(
        file: file, name: Self.pretty(entry.name), family: entry.version, role: .checkpoint,
        bytes: size, precision: Self.precision(lower), converted: true, modifier: entry.modifier,
        parts: entry.parts)
    }
    if lower.contains("_lora") {
      var title = base
      for tail in ["_lora_f16", "_lora_q8p", "_lora_q6p", "_lora"] where title.lowercased().hasSuffix(tail) {
        title = String(title.dropLast(tail.count))
        break
      }
      return InstalledModel(
        file: file, name: Self.pretty(title), family: "", role: .lora, bytes: size,
        precision: nil, converted: false)
    }
    if let entry = catalog[file] {
      return InstalledModel(
        file: file, name: entry.name, family: entry.version, role: .checkpoint, bytes: size,
        precision: Self.precision(lower), converted: false, modifier: entry.modifier,
        parts: entry.parts)
    }
    if helpers.contains(file) { return nil }
    let helperWords = ["vae", "clip", "t5", "qwen_3", "encoder", "_te_", "upscaler", "controlnet"]
    if helperWords.contains(where: { lower.contains($0) }) || size < 400_000_000 { return nil }
    return InstalledModel(
      file: file, name: Self.pretty(Self.withoutTechnicalTail(base)), family: "",
      role: .checkpoint, bytes: size, precision: Self.precision(lower), converted: false)
  }

  // MARK: adding

  /// Files dropped on a window or chosen with "Добавить файл…".
  func add(_ urls: [URL], origin: ImportOrigin = .dropped) {
    for url in urls {
      guard ["safetensors", "ckpt", "pt", "pth"].contains(url.pathExtension.lowercased()) else {
        continue
      }
      if ImportRunner.isEngineFormat(url) {
        // already in the engine's format: it only has to be in the folder
        copyEngineFile(url)
        continue
      }
      if jobs.contains(where: { $0.source.path == url.path && $0.failure == nil }) { continue }
      forgetFailure(url)
      folderWatch.cancelled[url.path] = nil  // dropped again on purpose, so it is wanted after all
      enqueue(url, origin: origin)
    }
    rescan()
  }

  /// The copy can be many gigabytes, so it runs off the main actor and under a temporary name
  /// the folder scan does not list; only the whole file gets its real name. A name that is
  /// taken is never overwritten: the copy gets a free one.
  private func copyEngineFile(_ url: URL) {
    guard !isInFolder(url) else { return }
    let destination = freeName(for: url.lastPathComponent)
    let key = destination.lastPathComponent.lowercased()
    copying.insert(key)
    let part = URL(fileURLWithPath: destination.path + ".part")
    // big models keep their weights in a sidecar next to the .ckpt (see `delete`)
    let sidecar = URL(fileURLWithPath: url.path + "-tensordata")
    let sidecarCopy = URL(fileURLWithPath: destination.path + "-tensordata")
    Task { [weak self] in
      let failure: String? = await Task.detached(priority: .utility) { () -> String? in
        let fm = FileManager.default
        var madeSidecar = false
        do {
          try fm.copyItem(at: url, to: part)
          if fm.fileExists(atPath: sidecar.path) {
            try fm.copyItem(at: sidecar, to: sidecarCopy)
            madeSidecar = true
          }
          try fm.moveItem(at: part, to: destination)
          return nil
        } catch {
          // both names were free a moment ago, so what is there now is this half-done copy
          try? fm.removeItem(at: part)
          if madeSidecar { try? fm.removeItem(at: sidecarCopy) }
          return error.localizedDescription
        }
      }.value
      guard let self else { return }
      self.copying.remove(key)
      if let failure { self.reportCopyFailure(of: url, failure) }
      self.rescan()
    }
  }

  private func reportCopyFailure(of url: URL, _ message: String) {
    let reason = "не скопировался в папку моделей: \(message)"
    var job = ImportJob(
      source: url, name: Self.pretty(url.deletingPathExtension().lastPathComponent),
      role: .checkpoint, origin: .dropped)
    job.stage = .failed(reason)
    jobs.removeAll { $0.source.path == url.path }
    jobs.append(job)
    onFailure(job, reason)
  }

  private func freeName(for file: String) -> URL {
    let fm = FileManager.default
    func taken(_ name: String) -> Bool {
      let path = modelsDir.appendingPathComponent(name).path
      return copying.contains(name.lowercased()) || fm.fileExists(atPath: path)
        || fm.fileExists(atPath: path + "-tensordata") || fm.fileExists(atPath: path + ".part")
    }
    var name = file
    var n = 2
    while taken(name) {
      name = Self.numbered(file, n)
      n += 1
    }
    return modelsDir.appendingPathComponent(name)
  }

  /// "model_f16.ckpt" becomes "model_2_f16.ckpt": the counter goes in front of the precision
  /// tail, because the library reads that off the end of the name.
  static func numbered(_ file: String, _ n: Int) -> String {
    let ext = (file as NSString).pathExtension
    let base = (file as NSString).deletingPathExtension
    let stem = withoutTechnicalTail(base)
    let tail = String(base.dropFirst(stem.count))
    return "\(stem)_\(n)\(tail)" + (ext.isEmpty ? "" : "." + ext)
  }

  func pickFiles() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = ["safetensors", "ckpt", "pt", "pth"]
      .compactMap { UTType(filenameExtension: $0) }
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = true
    panel.message = "Модели и LoRA: .safetensors с Civitai, Hugging Face и других сайтов"
    guard panel.runModal() == .OK else { return }
    add(panel.urls)
  }

  func download(_ entry: CatalogEntry) {
    guard !jobs.contains(where: { $0.catalogEntry?.file == entry.file }) else { return }
    var job = ImportJob(
      source: modelsDir.appendingPathComponent(entry.file), name: entry.name, role: .checkpoint,
      origin: .catalog)
    job.catalogEntry = entry
    jobs.append(job)
    runNext()
  }

  func compress(_ model: InstalledModel, plan: CompressionPlan = .eightBit, keepOriginal: Bool = false) {
    guard model.canCompress, !jobs.contains(where: { $0.source.lastPathComponent == model.file })
    else { return }
    var job = ImportJob(
      source: modelsDir.appendingPathComponent(model.file), name: model.name, role: .checkpoint,
      origin: .library)
    job.compressVersion = model.family
    job.compressPlan = plan
    job.keepOriginal = keepOriginal
    jobs.append(job)
    runNext()
  }

  private func enqueue(_ url: URL, origin: ImportOrigin) {
    jobs.removeAll { $0.source.path == url.path }
    jobs.append(
      ImportJob(
        source: url, name: Self.pretty(url.deletingPathExtension().lastPathComponent),
        role: Self.role(of: url), origin: origin))
    runNext()
  }

  /// What a dropped file is, judging by what is inside it.
  private static func role(of url: URL) -> ModelRole {
    if ImportRunner.looksLikeLoRA(url) { return .lora }
    return ImportRunner.looksLikePart(url) ? .part : .checkpoint
  }

  // MARK: running the queue, one at a time

  private func runNext() {
    guard !running, let job = jobs.first(where: { $0.stage == .waiting }) else { return }
    running = true
    Task { [weak self] in
      guard let self else { return }
      await self.run(job)
      self.running = false
      self.runNext()
    }
  }

  private func run(_ job: ImportJob) async {
    let id = job.id
    let report: ImportRunner.Report = { [weak self] stage, progress in
      self?.advance(id, stage, progress)
    }
    advance(id, .starting, 0)
    do {
      switch (job.origin, job.role) {
      case (.relocate, _):
        try await relocate(job, report: report)
      case (.catalog, _):
        try await download(job, report: report)
      case (_, .upscaler):
        let file = try await ImportRunner.fetch(job.source.lastPathComponent, report: report)
        finish(id, file: file, note: nil)
      case (.library, _):
        let file = try await ImportRunner.compress(
          job.source.lastPathComponent, version: job.compressVersion ?? "", plan: job.compressPlan,
          keepOriginal: job.keepOriginal, engine: engineHooks(), cancel: job.cancel, report: report)
        finish(id, file: file, note: nil)
      case (_, .part):
        let file = try await ImportRunner.importPart(job.source, cancel: job.cancel, report: report)
        finish(id, file: file, note: nil)
      case (_, .lora):
        let file = try await ImportRunner.importLoRA(
          job.source, fallbackFamily: fallbackFamily(), cancel: job.cancel, report: report)
        finish(id, file: file, note: nil)
      case (_, .checkpoint):
        try await convertCheckpoint(job, report: report)
      }
    } catch is CancellationError {
      rememberCancelled(job)
      jobs.removeAll { $0.id == id }
      rescan()
    } catch {
      let reason = ImportRunner.explain(error)
      if let i = jobs.firstIndex(where: { $0.id == id }) { jobs[i].stage = .failed(reason) }
      if let failed = jobs.first(where: { $0.id == id }) { onFailure(failed, reason) }
      if isLooseFile(job) { rememberFailure(job.source, reason) }
      rescan()
    }
  }

  /// Models moved to the external disk or brought back.
  private func relocate(_ job: ImportJob, report: @escaping ImportRunner.Report) async throws {
    if job.moveBack {
      try await ImportRunner.bringBack(
        job.moveFiles, engine: engineHooks(), cancel: job.cancel, report: report)
    } else {
      guard let external = ModelsFolder.external else {
        throw ImportError.failed("не выбрана папка на внешнем диске")
      }
      try await ImportRunner.moveOut(
        job.moveFiles, to: external, engine: engineHooks(), cancel: job.cancel, report: report)
    }
    jobs.removeAll { $0.id == job.id }
    rescan()
  }

  /// A model from the catalog, downloaded into the folder.
  private func download(_ job: ImportJob, report: @escaping ImportRunner.Report) async throws {
    guard let entry = job.catalogEntry, let catalog else {
      throw ImportError.failed("каталог сейчас недоступен")
    }
    advance(job.id, .downloading, 0)
    let watch = catalog.$progress.sink { fraction in report(.downloading, fraction) }
    let ok = await withCheckedContinuation { continuation in
      catalog.download(entry, into: modelsDir) { continuation.resume(returning: $0) }
    }
    watch.cancel()
    guard ok else {
      throw ImportError.failed(catalog.note.isEmpty ? "не скачалась" : catalog.note)
    }
    finish(job.id, file: entry.file, note: nil)
  }

  /// A whole checkpoint converted into the engine's format.
  private func convertCheckpoint(_ job: ImportJob, report: @escaping ImportRunner.Report) async throws {
    let writing = ImportRunner.cleanedName(job.source) + "_f16.ckpt"
    hidden.insert(writing)
    defer { hidden.remove(writing) }
    // the half-written file stays out of the list only until the engine comes back with it
    let base = engineHooks()
    let hooks = EngineHooks(
      pause: base.pause,
      resume: { [weak self] made, replacing in
        self?.hidden.remove(writing)
        self?.rescan()
        await base.resume(made, replacing)
      },
      waitIdle: base.waitIdle)
    let result = try await ImportRunner.importCheckpoint(
      job.source, engineTag: engineTag(), engine: hooks, cancel: job.cancel, plan: importPlan,
      report: report)
    finish(job.id, file: result.file, note: result.note)
  }

  private func advance(_ id: UUID, _ stage: JobStage, _ progress: Double) {
    guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
    let current = jobs[i].stage
    if stage.order < current.order { return }
    if stage != current {
      jobs[i].stage = stage
      jobs[i].stageStarted = Date()
    }
    jobs[i].progress = min(1, max(0, progress))
  }

  private func finish(_ id: UUID, file: String, note: String?) {
    guard let job = jobs.first(where: { $0.id == id }) else { return }
    // the original that lay in the models folder is not needed any more
    if job.origin == .dropped || job.origin == .folder, isInFolder(job.source) {
      try? FileManager.default.trashItem(at: job.source, resultingItemURL: nil)
    }
    rescan()
    if let i = jobs.firstIndex(where: { $0.id == id }) {
      if let note {
        jobs[i].stage = .done
        jobs[i].result = file
        jobs[i].note = note
      } else {
        // a plain success leaves nothing to read: the model is simply in the list now
        jobs.remove(at: i)
      }
    }
    if let model = installed.first(where: { $0.file == file }) { onReady(model) }
  }

  // MARK: row actions

  func cancel(_ job: ImportJob) {
    if job.stage == .waiting {
      rememberCancelled(job)
      jobs.removeAll { $0.id == job.id }
    } else {
      job.cancel.stop()
    }
  }

  /// A cancelled import leaves its source in the models folder, and the next scan would
  /// queue it again straight away. The file is skipped as it is now; if it changes or goes
  /// away the memory goes too.
  private func rememberCancelled(_ job: ImportJob) {
    guard isLooseFile(job), let stamp = Self.stamp(of: job.source) else { return }
    folderWatch.cancelled[job.source.path] = stamp
  }

  /// A file someone put into the models folder, as opposed to a model the library made or
  /// downloaded. Only a loose file can be found again by the folder scan.
  private func isLooseFile(_ job: ImportJob) -> Bool {
    job.origin == .folder || (job.origin == .dropped && isInFolder(job.source))
  }

  /// Whether `dismiss` sends the file to the Trash. Only a loose file that someone put or
  /// dropped into the models folder qualifies. After a failed compress the file in the folder
  /// is the installed model, after a failed download it is a finished one: both stay.
  func dismissTrashesFile(_ job: ImportJob) -> Bool {
    job.failure != nil && (job.origin == .folder || job.origin == .dropped)
      && isInFolder(job.source)
  }

  /// A failed loose file goes to the Trash, otherwise it would be picked up again; any other
  /// row is simply forgotten and its file stays where it is.
  func dismiss(_ job: ImportJob) {
    if dismissTrashesFile(job) {
      try? FileManager.default.trashItem(at: job.source, resultingItemURL: nil)
    }
    forgetFailure(job.source)
    jobs.removeAll { $0.id == job.id }
  }

  func retry(_ job: ImportJob) {
    forgetFailure(job.source)
    jobs.removeAll { $0.id == job.id }
    if job.origin == .catalog, let entry = job.catalogEntry {
      download(entry)
    } else if job.origin == .fileServer, let upscaler = Upscalers.model(job.source.lastPathComponent) {
      fetch(upscaler)
    } else if job.origin == .library {
      // enqueue would drop the family the compressor needs, and it would fail every time
      var again = ImportJob(
        source: job.source, name: job.name, role: job.role, origin: .library)
      again.compressVersion = job.compressVersion
      again.compressPlan = job.compressPlan
      again.keepOriginal = job.keepOriginal
      jobs.append(again)
      runNext()
    } else if job.origin == .dropped, !isInFolder(job.source),
      ImportRunner.isEngineFormat(job.source)
    {
      // a copy into the folder that failed: copy it again
      add([job.source])
    } else {
      enqueue(job.source, origin: job.origin)
    }
  }

  func reveal(_ url: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  func reveal(_ model: InstalledModel) {
    reveal(modelsDir.appendingPathComponent(model.file))
  }

  func delete(_ model: InstalledModel) {
    let url = modelsDir.appendingPathComponent(model.file)
    let data = URL(fileURLWithPath: url.path + "-tensordata")
    for item in [url, data] {
      // a model on the external disk goes from there too, not only its link
      if let target = ModelMover.linkTarget(item) {
        if FileManager.default.fileExists(atPath: target.path) {
          try? FileManager.default.trashItem(at: target, resultingItemURL: nil)
        }
        try? FileManager.default.removeItem(at: item)
      } else if FileManager.default.fileExists(atPath: item.path) {
        try? FileManager.default.trashItem(at: item, resultingItemURL: nil)
      }
    }
    if model.role == .part {
      ModelParts.remove(model.file, in: modelsDir)
    } else if model.converted {
      CustomModels.remove(model.file, in: modelsDir)
    }
    ModelPrefs.save(nil, for: model.file)
    rescan()
  }

  // MARK: external disk

  /// What a model takes with it: itself and the companions (encoders, decoders) that no model
  /// staying on the Mac needs.
  func filesToMove(_ models: [InstalledModel]) -> [String] {
    let moving = Set(models.map(\.file))
    let custom = CustomModels.entries(in: modelsDir)
    let catalog = CatalogCache.entries()
    func companions(_ file: String) -> [String] {
      custom[file]?.companions ?? catalog[file]?.companions ?? []
    }
    let staying = installed.filter { !moving.contains($0.file) && $0.storage == .mac }
    let neededHere = Set(staying.flatMap { companions($0.file) })
    var files: [String] = []
    for model in models {
      files.append(model.file)
      for companion in companions(model.file)
      where !neededHere.contains(companion) && !files.contains(companion)
        && ModelMover.linkTarget(modelsDir.appendingPathComponent(companion)) == nil
        && FileManager.default.fileExists(atPath: modelsDir.appendingPathComponent(companion).path)
      {
        files.append(companion)
      }
    }
    return ModelMover.expand(files, in: modelsDir)
  }

  /// What comes back with a model: itself and its companions that are on the disk.
  func filesToBringBack(_ model: InstalledModel) -> [String] {
    let custom = CustomModels.entries(in: modelsDir)
    let companions = custom[model.file]?.companions ?? CatalogCache.entries()[model.file]?.companions ?? []
    let names = ([model.file] + companions).filter {
      ModelMover.linkTarget(modelsDir.appendingPathComponent($0)) != nil
    }
    return ModelMover.expand(names, in: modelsDir).filter {
      ModelMover.linkTarget(modelsDir.appendingPathComponent($0)) != nil
    }
  }

  func moveToDisk(_ models: [InstalledModel]) {
    let local = models.filter { $0.storage == .mac }
    guard !local.isEmpty else { return }
    var job = ImportJob(
      source: modelsDir.appendingPathComponent(local[0].file),
      name: local.count == 1 ? local[0].name : "\(local.count) моделей", role: local[0].role,
      origin: .relocate)
    job.moveFiles = filesToMove(local)
    jobs.append(job)
    runNext()
  }

  func bringBack(_ model: InstalledModel) {
    var job = ImportJob(
      source: modelsDir.appendingPathComponent(model.file), name: model.name, role: model.role,
      origin: .relocate)
    job.moveFiles = filesToBringBack(model)
    job.moveBack = true
    jobs.append(job)
    runNext()
  }

  /// Bytes of what would move, for the picker.
  func bytesToMove(_ models: [InstalledModel]) -> Int64 {
    filesToMove(models).reduce(0) { total, name in
      let url = modelsDir.appendingPathComponent(name)
      return total + (((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0)
    }
  }

  private func isInFolder(_ url: URL) -> Bool {
    url.deletingLastPathComponent().standardizedFileURL.path == modelsDir.standardizedFileURL.path
  }

  // MARK: remembered failures

  private func failures() -> [String: String] {
    UserDefaults.standard.dictionary(forKey: failedKey) as? [String: String] ?? [:]
  }

  /// A failure belongs to a file as it was: the same name with another size or date is a
  /// different file (a download that finished later), and deserves a new try.
  private static func failureKey(_ url: URL, _ stamp: FileStamp) -> String {
    "\(url.path)\t\(stamp.size)\t\(stamp.modified?.timeIntervalSince1970 ?? 0)"
  }

  private static func stamp(of url: URL) -> FileStamp? {
    // a fresh URL: one from a directory listing can hold cached, outdated values
    let fresh = URL(fileURLWithPath: url.path)
    guard
      let values = try? fresh.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    else { return nil }
    return FileStamp(size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate)
  }

  private func rememberFailure(_ url: URL, _ reason: String) {
    guard let stamp = Self.stamp(of: url) else { return }
    var all = failures().filter { !Self.isFailure(of: url, $0.key) }
    all[Self.failureKey(url, stamp)] = reason
    UserDefaults.standard.set(all, forKey: failedKey)
  }

  /// Drops every remembered failure of this path, whatever the file looked like then; this
  /// also sweeps entries kept under the bare path by earlier versions.
  private func forgetFailure(_ url: URL) {
    let all = failures()
    let kept = all.filter { !Self.isFailure(of: url, $0.key) }
    guard kept.count != all.count else { return }
    UserDefaults.standard.set(kept, forKey: failedKey)
  }

  private static func isFailure(of url: URL, _ key: String) -> Bool {
    key == url.path || key.hasPrefix(url.path + "\t")
  }

  // MARK: names

  static func pretty(_ raw: String) -> String {
    raw.replacingOccurrences(of: "_", with: " ")
      .split(separator: " ", omittingEmptySubsequences: true)
      .joined(separator: " ")
  }

  static func withoutTechnicalTail(_ base: String) -> String {
    var name = base
    var changed = true
    while changed {
      changed = false
      for tail in ["_f16", "_q8p", "_q6p", "_q5p", "_q4p", "_i8x", "_svd"]
      where name.lowercased().hasSuffix(tail) {
        name = String(name.dropLast(tail.count))
        changed = true
      }
    }
    return name
  }

  static func precision(_ lower: String) -> String? {
    if lower.contains("_f16") { return "16 бит" }
    if lower.contains("q8p") || lower.contains("i8x") { return "8 бит" }
    if lower.contains("q6p") || lower.contains("i6x") { return "6 бит" }
    if lower.contains("q5p") || lower.contains("i5x") { return "5 бит" }
    if lower.contains("q4p") || lower.contains("i4x") { return "4 бита" }
    if lower.contains("i3x") { return "3 бита" }
    return nil
  }
}
