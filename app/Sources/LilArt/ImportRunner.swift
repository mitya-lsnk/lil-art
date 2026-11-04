import AppKit
import Foundation
import MediaGenerationKit

/// Where an import is. The steps are the same whether the file came from the catalog, was
/// dropped on the window or simply appeared in the models folder.
enum JobStage: Equatable {
  case waiting
  case starting
  case fetchingTool
  case downloading
  case unpacking
  case converting
  case compressing
  case moving
  case swapping
  case done
  case failed(String)

  var label: String {
    switch self {
    case .waiting: return "В очереди"
    case .starting: return "Начинаю"
    case .fetchingTool: return "Качаю конвертер"
    case .downloading: return "Скачиваю"
    case .unpacking: return "Раскрываю fp8"
    case .converting: return "Конвертирую"
    case .compressing: return "Сжимаю"
    case .moving: return "Переношу"
    case .swapping: return "Подменяю файл"
    case .done: return "Готова"
    case .failed: return "Не получилось"
    }
  }

  /// Late progress reports from a step that has already finished must not pull a job back.
  var order: Int {
    switch self {
    case .waiting: return 0
    case .starting: return 1
    case .fetchingTool: return 2
    case .downloading: return 3
    case .unpacking: return 4
    case .converting: return 5
    case .compressing, .moving: return 6
    case .swapping: return 7
    case .done, .failed: return 8
    }
  }

  var isRunning: Bool { order > 0 && order < 8 }
}

/// Lets a running import be stopped from its row.
final class CancelFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var stopped = false
  private var process: Process?

  var isStopped: Bool {
    lock.lock()
    defer { lock.unlock() }
    return stopped
  }

  func stop() {
    lock.lock()
    stopped = true
    let running = process
    lock.unlock()
    running?.terminate()
  }

  func attach(_ running: Process?) {
    lock.lock()
    process = running
    let already = stopped
    lock.unlock()
    if already { running?.terminate() }
  }

  func check() throws {
    if isStopped { throw CancellationError() }
  }
}

/// What an import needs from the engine. It is stopped only while it truly has to be: during
/// the conversion, which wants its memory, and for the seconds a compressed file takes the
/// place of the original.
struct EngineHooks {
  let pause: () async -> Void
  /// The file to select once the engine is back, and the file it replaces, if any.
  let resume: (_ made: String?, _ replacing: String?) async -> Void
  let waitIdle: () async -> Void
}

enum ImportError: Error {
  case failed(String)
  case http(Int)
  case noRelease
  case crashed(String)
  case exited(String)
}

/// The conversion steps themselves, with no interface of their own: they report a stage and
/// a fraction, and the model library shows it.
///
/// Whole checkpoints go through the command-line tool Draw Things publishes next to the engine
/// in every release; it is fetched once from the same release, so new families arrive with an
/// engine update and never need a new build of this app. LoRAs go through the importer in the
/// kit.
@available(macOS 26, *)
@MainActor
enum ImportRunner {
  typealias Report = (JobStage, Double) -> Void

  static var modelsDir: URL { ModelsFolder.url }

  static var tool: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("lil-art/engine/draw-things-cli")
  }

  // MARK: checkpoints

  /// Returns the engine file the model ended up in, and a note when something was left undone.
  static func importCheckpoint(
    _ source: URL, engineTag: String, engine: EngineHooks, cancel: CancelFlag,
    plan: CompressionPlan? = nil, report: @escaping Report
  ) async throws -> (file: String, note: String?) {
    let started = Date()
    let fm = FileManager.default
    let target = modelsDir.appendingPathComponent(cleanedName(source) + "_f16.ckpt")
    let existedBefore = fm.fileExists(atPath: target.path)
    // The importer runs with --replace. A copy that was already there waits under this name
    // meanwhile, so a stopped or failed run cannot leave a half-overwritten file that still
    // looks like a good model. The model list ignores the ending.
    let previous = URL(fileURLWithPath: target.path + ".prev")
    var setAside = false
    var imported: String?
    var paused = false
    var unpacked: URL?
    defer { if let unpacked { try? FileManager.default.removeItem(at: unpacked) } }
    sweepStaleTemporaries()

    do {
      try await ensureTool(tag: engineTag, report: report)
      try cancel.check()

      var importSource = source
      if ScaledCheckpoint.needsDequantizing(source) {
        // only the disk is needed here, so the engine keeps running
        report(.unpacking, 0)
        let folder = importCache
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let out = folder.appendingPathComponent(source.lastPathComponent)
        unpacked = out
        let progress: @Sendable (Double) -> Void = { fraction in
          Task { @MainActor in report(.unpacking, fraction) }
        }
        try await Task.detached(priority: .userInitiated) {
          try ScaledCheckpoint.dequantize(
            source, to: out, progress: progress, shouldStop: { cancel.isStopped })
        }.value
        importSource = out
      }
      try cancel.check()

      report(.converting, 0)
      await engine.pause()
      paused = true
      if existedBefore {
        // a copy left by an earlier crash is moved to the Trash rather than overwritten
        if fm.fileExists(atPath: previous.path) {
          try fm.trashItem(at: previous, resultingItemURL: nil)
        }
        try fm.moveItem(at: target, to: previous)
        setAside = true
      }
      let log = try await runImport(importSource, cancel: cancel, report: report)
      if let temporary = unpacked {
        try? FileManager.default.removeItem(at: temporary)
        unpacked = nil
      }
      // The tool prints "Model imported:" only when no companion download warned; it has
      // written the file and custom.json either way. A clean exit and a file at the expected
      // name is therefore a finished conversion.
      let file = log.imported ?? target.lastPathComponent
      guard bytes(modelsDir.appendingPathComponent(file)) > 50_000_000
      else { throw ImportError.failed("конвертер закончил, но модель не появилась") }
      imported = file
      let importedBytes = bytes(modelsDir.appendingPathComponent(file))
      // the new conversion stands, the copy it replaced is no longer wanted
      if setAside {
        try? fm.removeItem(at: previous)
        setAside = false
      }

      // the model is usable right away, so the engine comes back before anything else
      await engine.resume(file, nil)
      paused = false

      var note: String?
      let warning = log.warning.trimmingCharacters(in: .whitespacesAndNewlines)
      if !warning.isEmpty {
        let detail = warning.split(whereSeparator: \.isNewline).prefix(2).joined(separator: "; ")
        note =
          "не докачались нужные модели файлы, без интернета она может не запуститься ("
          + String(detail.prefix(240)) + ")"
      }
      // The importer leaves Wan's picture-to-video models marked text-to-video ("none"); their
      // 36 input channels (noise, mask, picture) say otherwise, and without the mark the
      // engine ignores the first frame.
      if let entry = CustomModels.entries(in: modelsDir)[file], entry.version.hasPrefix("wan"),
        entry.modifier.isEmpty || entry.modifier == "none", wanInputChannels(source) == 36
      {
        try? CustomModels.setValue("inpainting", for: "modifier", of: file, in: modelsDir)
      }
      // An 8-bit download leaves the importer at 16 bits, twice its size: it goes back to 8.
      // A plan chosen in the models window squeezes every import, whatever it came as.
      let squeeze = plan ?? (Double(importedBytes) > Double(bytes(source)) * 1.5 ? .eightBit : nil)
      if let squeeze, let version = CustomModels.entries(in: modelsDir)[file]?.version,
        WeightCompressor.canCompress(version)
      {
        do {
          let smaller = try await compress(
            file, version: version, plan: squeeze, engine: engine, cancel: cancel, report: report)
          return (smaller, note)
        } catch is CancellationError {
          return (file, joined(note, "сжатие отменено, модель осталась 16-битной"))
        } catch {
          return (
            file,
            joined(note, "сжать не вышло, модель осталась 16-битной: " + explain(error))
          )
        }
      }
      return (file, note)
    } catch {
      if imported == nil {
        if setAside {
          // whatever sits at the target now was written by this run; the old copy comes back
          removePartial(target)
          try? fm.moveItem(at: previous, to: target)
        } else if !existedBefore {
          removeLeftovers(target, since: started)
          // the importer records the model before it is checked, so the entry goes too
          if !fm.fileExists(atPath: target.path) {
            CustomModels.remove(target.lastPathComponent, in: modelsDir)
          }
        }
      }
      if paused { await engine.resume(nil, nil) }
      if cancel.isStopped { throw CancellationError() }
      throw error
    }
  }

  /// Writes the 8-bit copy beside the original while the engine keeps working, then swaps it in
  /// the moment nothing is being generated. The copy is written under a name the model list
  /// ignores, so an interrupted run never shows up as a broken model.
  /// Writes a smaller copy under `plan` and puts it in the original's place, or beside it when
  /// `keepOriginal`.
  static func compress(
    _ file: String, version: String, plan: CompressionPlan = .eightBit, keepOriginal: Bool = false,
    engine: EngineHooks, cancel: CancelFlag, report: @escaping Report
  ) async throws -> String {
    report(.compressing, 0)
    let fm = FileManager.default
    var smaller = uniqueCompressedName(file, version: version, plan: plan)
    let input = modelsDir.appendingPathComponent(file)
    let partial = modelsDir.appendingPathComponent(smaller + ".part")
    let inputBytes = bytes(input)
    let progress: @Sendable (Double) -> Void = { fraction in
      Task { @MainActor in report(.compressing, fraction) }
    }
    removePartial(partial)
    do {
      try await Task.detached(priority: .userInitiated) {
        try WeightCompressor.compress(
          input: input.path, output: partial.path, version: version, plan: plan,
          progress: progress, shouldStop: { cancel.isStopped })
      }.value
      // Every tensor was written by now (the compressor refuses otherwise); a result far below
      // what the plan should give still means something was cut short.
      let floor = Int64(Double(inputBytes) * Double(max(3, plan.bits)) / 16 * 0.5)
      guard bytes(partial) > max(10_000_000, floor) else {
        throw WeightCompressor.Failure.empty
      }
    } catch {
      removePartial(partial)
      throw cancel.isStopped ? CancellationError() : error
    }
    let partialBytes = bytes(partial)

    report(.swapping, 1)
    await engine.waitIdle()
    // a stop pressed while waiting for the engine: nothing has changed yet
    if cancel.isStopped {
      removePartial(partial)
      throw CancellationError()
    }
    await engine.pause()
    var moved = false
    var output = modelsDir.appendingPathComponent(smaller)
    do {
      try cancel.check()
      if fm.fileExists(atPath: output.path) {
        // something took the name while the copy was being written; it is not ours to replace
        smaller = uniqueCompressedName(file, version: version, plan: plan)
        output = modelsDir.appendingPathComponent(smaller)
      }
      try fm.moveItem(at: partial, to: output)
      moved = true
      guard bytes(output) == partialBytes else { throw WeightCompressor.Failure.empty }
      if keepOriginal {
        try CustomModels.duplicate(file, as: smaller, in: modelsDir)
      } else {
        try CustomModels.rename(file, to: smaller, in: modelsDir)
      }
    } catch {
      // only a file this run just put in place is removed; the original is still untouched
      if moved { try? fm.removeItem(at: output) }
      removePartial(partial)
      await engine.resume(nil, nil)
      throw error
    }
    if !keepOriginal { try? fm.removeItem(at: input) }
    // settings saved for the model follow it to its new file
    if let saved = ModelPrefs.load(file) {
      ModelPrefs.save(saved, for: smaller)
      if !keepOriginal { ModelPrefs.save(nil, for: file) }
    }
    await engine.resume(smaller, keepOriginal ? nil : file)
    return smaller
  }

  // MARK: LoRA

  /// `cancel` is only checked between the steps: the importer itself cannot be interrupted.
  static func importLoRA(
    _ source: URL, fallbackFamily: String?, cancel: CancelFlag? = nil,
    report: @escaping Report
  ) async throws -> String {
    // LoKr and LoHa look like LoRA from the outside, but the engine cannot read them; the
    // importer even reports success and writes an empty file.
    if let kind = lycorisKind(source) {
      throw ImportError.failed("это \(kind), а не обычная LoRA. Движок такой формат не читает")
    }
    let name =
      source.deletingPathExtension().lastPathComponent
      .replacingOccurrences(of: " ", with: "_") + "_lora_f16.ckpt"
    let destination = modelsDir.appendingPathComponent(name)
    // Written under a name the model list ignores and moved into place only when whole, so a
    // failure never touches a LoRA of the same name that already works.
    let partial = URL(fileURLWithPath: destination.path + ".part")
    removePartial(partial)
    report(.converting, 0)
    let progress: @Sendable (Double) -> Void = { fraction in
      Task { @MainActor in report(.converting, fraction) }
    }
    do {
      try cancel?.check()
      try await Task.detached(priority: .userInitiated) {
        var importer = LoRAImporter(file: source)
        do {
          try importer.inspect()
        } catch where String(describing: error).contains("versionDetectionFailed") {
          // Many trainers write keys the detector does not recognise. The importer handles the
          // family fine once told, and the obvious guess is the model selected right now.
          guard let family = fallbackFamily,
            let forced = familyValue(type(of: importer.version), family)
          else { throw error }
          importer.version = forced
          try importer.inspect()
        }
        try importer.import(to: partial) { fraction in progress(fraction) }
      }.value
      try cancel?.check()
      guard bytes(partial) > 1_000_000 else {
        throw ImportError.failed("файл получился пустым: веса этой LoRA движок не распознал")
      }
      if FileManager.default.fileExists(atPath: destination.path) {
        // the same LoRA imported again: the new copy takes the place in one step
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: partial)
      } else {
        try FileManager.default.moveItem(at: partial, to: destination)
      }
      return name
    } catch {
      removePartial(partial)
      throw error
    }
  }

  /// What a Wan file's first layer takes in: 16 for text-to-video, 36 for picture-to-video.
  nonisolated static func wanInputChannels(_ url: URL) -> Int? {
    guard let header = ScaledCheckpoint.header(of: url),
      let entry = header.entries.first(where: { $0.key.hasSuffix("patch_embedding.weight") })?.value,
      entry.shape.count >= 2
    else { return nil }
    return entry.shape[1]
  }

  // MARK: moving to and from an external disk

  /// A model and its own companions to the external folder, links left in their places.
  static func moveOut(
    _ names: [String], to external: URL, engine: EngineHooks, cancel: CancelFlag,
    report: @escaping Report
  ) async throws {
    let dir = modelsDir
    report(.moving, 0)
    let progress: @Sendable (Double) -> Void = { fraction in
      Task { @MainActor in report(.moving, fraction) }
    }
    try await Task.detached(priority: .utility) {
      try ModelMover.copyOut(
        names, from: dir, to: external, progress: progress, shouldStop: { cancel.isStopped })
    }.value
    try cancel.check()
    report(.swapping, 1)
    await engine.waitIdle()
    await engine.pause()
    defer { Task { await engine.resume(nil, nil) } }
    try ModelMover.linkOut(names, from: dir, to: external)
  }

  /// The other way: copies back onto the Mac in place of the links, then off the disk.
  static func bringBack(
    _ names: [String], engine: EngineHooks, cancel: CancelFlag, report: @escaping Report
  ) async throws {
    let dir = modelsDir
    report(.moving, 0)
    let progress: @Sendable (Double) -> Void = { fraction in
      Task { @MainActor in report(.moving, fraction) }
    }
    let copies = try await Task.detached(priority: .utility) {
      try ModelMover.copyBack(names, to: dir, progress: progress, shouldStop: { cancel.isStopped })
    }.value
    if cancel.isStopped {
      copies.forEach { try? FileManager.default.removeItem(at: $0.copy) }
      throw CancellationError()
    }
    report(.swapping, 1)
    await engine.waitIdle()
    await engine.pause()
    defer { Task { await engine.resume(nil, nil) } }
    try ModelMover.swapBack(copies)
  }

  // MARK: model parts

  /// A retrained VAE or encoder goes into the folder in the engine's layout and is listed
  /// beside the standard part it copies; see `ModelParts`.
  static func importPart(_ source: URL, cancel: CancelFlag, report: @escaping Report)
    async throws -> String
  {
    let dir = modelsDir
    let catalog = CatalogCache.file
    report(.converting, 0)
    let progress: @Sendable (Double) -> Void = { fraction in
      Task { @MainActor in report(.converting, fraction) }
    }
    try cancel.check()
    // A big encoder spends some 20 minutes of every core on its 8-bit palettes; at utility
    // priority the Mac stays usable meanwhile.
    return try await Task.detached(priority: .utility) {
      try ModelParts.install(
        source, in: dir, catalog: catalog, progress: progress, shouldStop: { cancel.isStopped }
      ).file
    }.value
  }

  // MARK: the tool

  /// Kept in step with the engine: a different engine release means a fresh copy.
  private static func ensureTool(tag: String, report: @escaping Report) async throws {
    let fm = FileManager.default
    let defaults = UserDefaults.standard
    if fm.isExecutableFile(atPath: tool.path), tag.isEmpty || defaults.string(forKey: "cli.tag") == tag
    {
      return
    }
    report(.fetchingTool, 0)
    var wanted = tag.isEmpty ? try await latestTag() : tag
    let temp: URL
    do {
      temp = try await download(wanted, report: report)
    } catch ImportError.http(404) where !tag.isEmpty {
      // an older engine release may not carry the tool yet
      wanted = try await latestTag()
      temp = try await download(wanted, report: report)
    }
    do {
      try fm.createDirectory(
        at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
      if fm.fileExists(atPath: tool.path) { try fm.removeItem(at: tool) }
      try fm.moveItem(at: temp, to: tool)
      try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
    } catch {
      try? fm.removeItem(at: temp)
      throw error
    }
    defaults.set(wanted, forKey: "cli.tag")
  }

  nonisolated static func latestTag() async throws -> String {
    guard
      let url = URL(
        string: "https://api.github.com/repos/drawthingsai/draw-things-community/releases/latest")
    else { throw ImportError.noRelease }
    let (data, _) = try await URLSession.shared.data(from: url)
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let tag = json["tag_name"] as? String, !tag.isEmpty
    else { throw ImportError.noRelease }
    return tag
  }

  private static func download(_ tag: String, report: @escaping Report) async throws -> URL {
    guard
      let url = URL(
        string:
          "https://github.com/drawthingsai/draw-things-community/releases/download/\(tag)/draw-things-cli"
      )
    else { throw ImportError.http(0) }
    return try await downloadFile(url, stage: .fetchingTool, report: report)
  }

  /// A ready-made file from the engine's own file server, straight into the models folder.
  static func fetch(_ file: String, report: @escaping Report) async throws -> String {
    guard let encoded = file.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
      let url = URL(string: "https://static.libnnc.org/\(encoded)")
    else { throw ImportError.http(0) }
    sweepStaleTemporaries()
    report(.downloading, 0)
    let temp = try await downloadFile(url, stage: .downloading, report: report)
    let destination = modelsDir.appendingPathComponent(file)
    do {
      if FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination)
      }
      try FileManager.default.moveItem(at: temp, to: destination)
    } catch {
      try? FileManager.default.removeItem(at: temp)
      throw error
    }
    return file
  }

  private static func downloadFile(_ url: URL, stage: JobStage, report: @escaping Report)
    async throws -> URL
  {
    var observation: NSKeyValueObservation?
    defer { observation?.invalidate() }
    return try await withCheckedThrowingContinuation { continuation in
      let task = URLSession.shared.downloadTask(with: url) { location, response, error in
        if let error {
          continuation.resume(throwing: error)
          return
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code), let location else {
          // an error page body is of no use; the system would drop it, but not to rely on that
          if let location { try? FileManager.default.removeItem(at: location) }
          continuation.resume(throwing: ImportError.http(code))
          return
        }
        // the system deletes the file as soon as this handler returns
        let kept = FileManager.default.temporaryDirectory
          .appendingPathComponent("lil-art-download-" + UUID().uuidString)
        do {
          try FileManager.default.moveItem(at: location, to: kept)
          continuation.resume(returning: kept)
        } catch {
          try? FileManager.default.removeItem(at: location)
          try? FileManager.default.removeItem(at: kept)
          continuation.resume(throwing: error)
        }
      }
      observation = task.progress.observe(\.fractionCompleted) { progress, _ in
        let fraction = progress.fractionCompleted
        Task { @MainActor in report(stage, fraction) }
      }
      task.resume()
    }
  }

  private static func runImport(_ source: URL, cancel: CancelFlag, report: @escaping Report)
    async throws -> ImportLog
  {
    let process = Process()
    process.executableURL = tool
    process.arguments = [
      "models", "import", source.path, "--models-dir", modelsDir.path, "--replace",
    ]
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    let log = ImportLog()
    let forward: @Sendable ([ImportLog.Event]) -> Void = { events in
      Task { @MainActor in
        for event in events {
          switch event {
          case .importing(let fraction): report(.converting, fraction)
          case .fetching(let fraction): if let fraction { report(.converting, fraction) }
          }
        }
      }
    }
    out.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      let events = log.feed(data)
      if !events.isEmpty { forward(events) }
    }
    err.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      if !data.isEmpty { log.feedError(data) }
    }
    let status: (Int32, Process.TerminationReason) = try await withCheckedThrowingContinuation {
      continuation in
      process.terminationHandler = { p in
        continuation.resume(returning: (p.terminationStatus, p.terminationReason))
      }
      do {
        try process.run()
        cancel.attach(process)
      } catch {
        process.terminationHandler = nil
        continuation.resume(throwing: error)
      }
    }
    cancel.attach(nil)
    out.fileHandleForReading.readabilityHandler = nil
    err.fileHandleForReading.readabilityHandler = nil
    _ = log.feed(out.fileHandleForReading.readDataToEndOfFile())
    _ = log.flush()
    log.feedError(err.fileHandleForReading.readDataToEndOfFile())

    if cancel.isStopped { throw CancellationError() }
    if status.1 == .uncaughtSignal { throw ImportError.crashed(log.errors) }
    if status.0 != 0 { throw ImportError.exited(log.errors) }
    return log
  }

  // MARK: files

  nonisolated static func bytes(_ url: URL) -> Int64 {
    ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64) ?? 0
  }

  /// The importer names its output after the source file, cleaned the way the engine does it.
  nonisolated static func cleanedName(_ source: URL) -> String {
    var cleaned = ""
    for character in source.deletingPathExtension().lastPathComponent {
      cleaned +=
        character.isASCII && (character.isLetter || character.isNumber || character == ".")
        ? String(character) : "_"
    }
    return cleaned.lowercased()
  }

  /// `copy` above 1 numbers the name ("model_2_q8p.ckpt"); the ending stays last because the
  /// engine reads the kind of weights from it.
  nonisolated static func compressedName(
    _ file: String, version: String, plan: CompressionPlan = .eightBit, copy: Int = 1
  ) -> String {
    let ending = WeightCompressor.suffix(for: version, plan: plan)
    var stem = (file as NSString).deletingPathExtension
    // the old precision goes; "model_i8x" squeezed further is "model_i4x", not "model_i8x_i4x"
    if let range = stem.range(of: #"_(f16|q[4-8]p|i[3-8]x)$"#, options: .regularExpression) {
      stem = String(stem[..<range.lowerBound])
    }
    return stem + (copy > 1 ? "_\(copy)" : "") + ending
  }

  /// A name for the compressed copy that no file and no custom.json entry uses. A file already
  /// there is somebody's model and is never overwritten.
  private static func uniqueCompressedName(
    _ file: String, version: String, plan: CompressionPlan
  ) -> String {
    let taken = Set(CustomModels.entries(in: modelsDir).keys)
    var copy = 1
    while true {
      let name = compressedName(file, version: version, plan: plan, copy: copy)
      let path = modelsDir.appendingPathComponent(name).path
      if !taken.contains(name), !FileManager.default.fileExists(atPath: path) { return name }
      copy += 1
    }
  }

  private nonisolated static func joined(_ note: String?, _ more: String) -> String {
    note.map { $0 + "; " + more } ?? more
  }

  static var importCache: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("lil-art/cache/import")
  }

  /// Unpacked copies and download files are removed when their step ends. A crash or a forced
  /// quit skips that, and they are gigabytes, so anything over a day old goes at the next import.
  private static func sweepStaleTemporaries() {
    let fm = FileManager.default
    let limit = Date().addingTimeInterval(-24 * 3600)
    let places: [(folder: URL, prefix: String)] = [
      (importCache, ""), (fm.temporaryDirectory, "lil-art-download-"),
    ]
    for place in places {
      let urls =
        (try? fm.contentsOfDirectory(
          at: place.folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
      for url in urls where url.lastPathComponent.hasPrefix(place.prefix) {
        let modified =
          (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let modified, modified < limit { try? fm.removeItem(at: url) }
      }
    }
  }

  private nonisolated static func removeLeftovers(_ candidate: URL, since: Date) {
    guard
      let modified = (try? FileManager.default.attributesOfItem(atPath: candidate.path))?[
        .modificationDate] as? Date,
      modified >= since
    else { return }
    try? FileManager.default.removeItem(at: candidate)
  }

  nonisolated static func removePartial(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
    try? FileManager.default.removeItem(atPath: url.path + "-journal")
  }

  /// The engine's own weight files are SQLite databases; everything else with a model-like
  /// extension is something to import.
  nonisolated static func isEngineFormat(_ url: URL) -> Bool {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? handle.close() }
    guard let head = try? handle.read(upToCount: 15) else { return false }
    return head == Data("SQLite format 3".utf8)
  }

  /// Reads only the safetensors header. LoRA weight names carry "lora" or a LyCORIS marker; a
  /// whole checkpoint's never do.
  nonisolated static func looksLikeLoRA(_ url: URL) -> Bool {
    guard url.pathExtension.lowercased() == "safetensors", let text = headerText(url) else {
      return false
    }
    let markers = [
      "lora_up", "lora_down", "lora_a.", "lora_b.", "lora_te", "lora_unet", ".lora.", "lokr_w",
      "hada_w",
    ]
    return markers.contains { text.contains($0) }
  }

  /// A retrained VAE or encoder of a model already installed (`ModelParts`).
  nonisolated static func looksLikePart(_ url: URL) -> Bool {
    ModelParts.looksLikePart(url, models: ModelsFolder.url, catalog: CatalogCache.file)
  }

  nonisolated static func lycorisKind(_ url: URL) -> String? {
    guard let text = headerText(url) else { return nil }
    if text.contains("lokr_w") { return "LoKr" }
    if text.contains("hada_w") { return "LoHa" }
    return nil
  }

  private nonisolated static func headerText(_ url: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let lengthBytes = try? handle.read(upToCount: 8), lengthBytes.count == 8 else {
      return nil
    }
    let length = lengthBytes.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
    guard length > 0, length < 200_000_000,
      let header = try? handle.read(upToCount: Int(length))
    else { return nil }
    return String(decoding: header, as: UTF8.self).lowercased()
  }

  // MARK: what went wrong, in words

  nonisolated static func explain(_ error: Error) -> String {
    switch error {
    case is CancellationError:
      return "отменено"
    case ImportError.failed(let reason):
      return reason
    case ImportError.http(let code):
      return "конвертер не скачался, GitHub ответил \(code)"
    case ImportError.noRelease:
      return "на GitHub не нашёлся выпуск движка с конвертером"
    case ImportError.crashed(let text):
      return "конвертер упал на этом файле: такую модель он пока не умеет" + lastLine(text)
    case ImportError.exited(let text):
      let lower = text.lowercased()
      if lower.contains("no space") { return "на диске не хватило места" }
      if lower.contains("versiondetection") || lower.contains("tensornotfound")
        || lower.contains("datanotfound") || lower.contains("unsupported")
      {
        return "движок не узнал этот файл: это не целая модель или её семейство ему неизвестно"
      }
      return lastLine(text).isEmpty ? "конвертер завершился с ошибкой" : lastLine(text)
    case ScaledCheckpoint.Failure.unsupported(let what):
      return "веса ужаты способом, который движок пока не читает: \(what). Нужна версия fp8 или fp16"
    case ScaledCheckpoint.Failure.unreadable:
      return "файл не читается, возможно он скачался не до конца"
    case ScaledCheckpoint.Failure.noSpace(let gigabytes):
      return String(format: "на диске нужно хотя бы %.0f ГБ свободного места", gigabytes)
    case ModelMover.Failure.unreachable(let disk):
      return "диск «\(disk)» не подключён"
    case ModelMover.Failure.noSpace(let gigabytes):
      return String(format: "не хватает места: нужно %.0f ГБ", gigabytes)
    case ModelMover.Failure.mismatch(let file):
      return "\(file) скопировался не целиком, оригинал не тронут"
    case ModelMover.Failure.notLinked(let file):
      return "\(file) и так на Mac"
    case ModelParts.Failure.noStandard:
      return "не нашлось установленной модели, частью которой может быть этот файл: "
        + "сначала нужна сама модель, затем её VAE или кодировщик"
    case ModelParts.Failure.mismatch(let stock, let matched, let total):
      return "похоже на \(stock), но совпали только \(matched) слоёв из \(total): "
        + "это не дообученная копия, а другое устройство файла"
    case ModelParts.Failure.unreadable:
      return "файл не читается, возможно он скачался не до конца"
    case ModelParts.Failure.incomplete:
      return "часть весов не записалась"
    case ModelParts.Failure.noSpace(let gigabytes):
      return String(format: "на диске нужно хотя бы %.0f ГБ свободного места", gigabytes)
    case WeightCompressor.Failure.unsupportedFamily(let family):
      return "модели семейства \(family) сжимать не умею"
    case WeightCompressor.Failure.openFailed:
      return "не открылся файл модели"
    case WeightCompressor.Failure.empty:
      return "сжатый файл получился пустым"
    case WeightCompressor.Failure.incomplete:
      return "часть весов не прочиталась, сжатие остановлено"
    case WeightCompressor.Failure.noSpace(let gigabytes):
      return String(format: "на диске нужно хотя бы %.0f ГБ свободного места", gigabytes)
    default:
      let text = String(describing: error)
      if text.contains("versionDetectionFailed") || text.contains("modelVersionFailed") {
        return "не понятно, для какой модели эта LoRA. Выберите модель того же семейства и повторите"
      }
      return error.localizedDescription
    }
  }

  private nonisolated static func lastLine(_ text: String) -> String {
    let line =
      text.split(whereSeparator: \.isNewline).last.map(String.init)?
      .trimmingCharacters(in: .whitespaces) ?? ""
    return line.isEmpty ? "" : " (\(line))"
  }
}

/// What the tool prints, turned into progress. Lines end in "\n", download progress redraws
/// itself with "\r".
final class ImportLog: @unchecked Sendable {
  enum Event {
    case importing(Double)
    case fetching(Double?)
  }

  private let lock = NSLock()
  private var pending = ""
  private var inWarning = false
  private var _errors = ""
  private var _imported: String?
  private var _warning = ""

  var errors: String { locked { _errors } }
  var imported: String? { locked { _imported } }
  var warning: String { locked { _warning } }

  private func locked<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }

  func feedError(_ data: Data) {
    locked { _errors += String(decoding: data, as: UTF8.self) }
  }

  func feed(_ data: Data) -> [Event] {
    locked {
      pending += String(decoding: data, as: UTF8.self)
      var events: [Event] = []
      let breaks = CharacterSet(charactersIn: "\r\n")
      while let range = pending.rangeOfCharacter(from: breaks) {
        let line = String(pending[..<range.lowerBound])
        pending.removeSubrange(..<range.upperBound)
        events += parse(line)
      }
      return events
    }
  }

  func flush() -> [Event] {
    locked {
      let line = pending
      pending = ""
      return parse(line)
    }
  }

  private func parse(_ raw: String) -> [Event] {
    let line = raw.trimmingCharacters(in: .whitespaces)
    guard !line.isEmpty else { return [] }
    // the detected family is of no use here: the model's own custom.json entry carries it
    if line.hasPrefix("Detected: ") { return [] }
    if line.hasPrefix("Importing: ") {
      return [.importing((Self.percent(in: line) ?? 0) / 100)]
    }
    if line.hasPrefix("Model imported: ") {
      _imported = String(line.dropFirst("Model imported: ".count))
      return []
    }
    if line.hasPrefix("Dependency download warning") {
      inWarning = true
      return []
    }
    if inWarning {
      _warning += line + "\n"
      return []
    }
    if line.contains("%") {
      return [.fetching(Self.percent(in: line).map { $0 / 100 })]
    }
    return []
  }

  private static func percent(in line: String) -> Double? {
    guard let sign = line.firstIndex(of: "%") else { return nil }
    var digits = ""
    var index = sign
    while index > line.startIndex {
      index = line.index(before: index)
      let character = line[index]
      guard character.isNumber || character == "." else { break }
      digits.insert(character, at: digits.startIndex)
    }
    return Double(digits)
  }
}

/// The engine records converted models in custom.json next to the files: a display name and a
/// family for each.
enum CustomModels {
  struct Entry {
    let name: String
    let version: String
    /// "inpainting", "kontext" and friends: what the model wants on its input.
    let modifier: String
    /// Other files this model needs: its text encoder and picture decoder.
    let companions: [String]
    /// The swappable parts it names (VAE, text encoder, …), slot by slot.
    let parts: [ModelParts.Slot: String]
    let note: String
  }

  static func entries(in modelsDir: URL) -> [String: Entry] {
    guard let list = read(modelsDir) else { return [:] }
    var out: [String: Entry] = [:]
    for item in list {
      guard let file = item["file"] as? String else { continue }
      let companions = companionFiles(in: item, file: file)
      out[file] = Entry(
        name: (item["name"] as? String) ?? file, version: (item["version"] as? String) ?? "",
        modifier: (item["modifier"] as? String) ?? "", companions: companions,
        parts: ModelParts.parts(of: item), note: (item["note"] as? String) ?? "")
    }
    return out
  }

  /// Points every mention of a file at its replacement. A model can name itself more than once:
  /// Krea 2 lists its own file as its clip encoder too.
  static func setValue(_ value: String, for key: String, of file: String, in modelsDir: URL) throws {
    guard var list = read(modelsDir), let index = list.firstIndex(where: { ($0["file"] as? String) == file })
    else { return }
    list[index][key] = value
    try write(list, modelsDir)
  }

  static func rename(_ old: String, to new: String, in modelsDir: URL) throws {
    guard var list = read(modelsDir) else { return }
    // An entry already named after the new file (left by a file that is gone) would otherwise
    // sit beside the renamed one with the same "file"; the one being renamed wins.
    if old != new, list.contains(where: { ($0["file"] as? String) == old }) {
      list.removeAll { ($0["file"] as? String) == new }
    }
    for index in list.indices {
      for (key, value) in list[index] where (value as? String) == old {
        list[index][key] = new
      }
    }
    try write(list, modelsDir)
  }

  /// A second entry for a copy of a model: the same description under the copy's file name.
  static func duplicate(_ file: String, as copy: String, in modelsDir: URL) throws {
    guard var list = read(modelsDir),
      var entry = list.first(where: { ($0["file"] as? String) == file })
    else { return }
    // a model naming itself (Krea's "clip" lives inside it) names the copy instead
    for (key, value) in entry where (value as? String) == file { entry[key] = copy }
    list.removeAll { ($0["file"] as? String) == copy }
    list.append(entry)
    try write(list, modelsDir)
  }

  static func remove(_ file: String, in modelsDir: URL) {
    guard let list = read(modelsDir) else { return }
    let kept = list.filter { ($0["file"] as? String) != file }
    // nothing to drop: leave the engine's file alone rather than rewrite it
    if kept.count != list.count { try? write(kept, modelsDir) }
  }

  private static func read(_ modelsDir: URL) -> [[String: Any]]? {
    guard let data = try? Data(contentsOf: modelsDir.appendingPathComponent("custom.json")) else {
      return nil
    }
    return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
  }

  private static func write(_ list: [[String: Any]], _ modelsDir: URL) throws {
    let encoded = try JSONSerialization.data(
      withJSONObject: list, options: [.prettyPrinted, .sortedKeys])
    try encoded.write(to: modelsDir.appendingPathComponent("custom.json"), options: .atomic)
  }
}
