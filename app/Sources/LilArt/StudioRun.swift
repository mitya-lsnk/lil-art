import AVFoundation
import AppKit
import Combine
import CoreGraphics
import Darwin
import Foundation
import MediaGenerationKit
import SwiftUI
import UniformTypeIdentifiers

@available(macOS 26, *)
extension Studio {
  // MARK: generation

  // MARK: generation

  /// One picture or one clip, with everything it needs captured the moment the button was
  /// pressed. Settings changed afterwards apply to the next press, not to work that is
  /// already waiting — that is what "добавить в очередь" promises.
  enum Job {
    case image(ImageJob)
    case video(VideoJob)
  }


  struct ImageJob {
    /// `prompt` holds the text as typed; it is translated when its turn comes.
    var request: ImageRequest
    var suffix: String
    /// The model's display name, for the overlay.
    var modelName: String
    /// Pro mode: the exact count. Simple mode: nil, and `quality` scales whatever the
    /// model recommends once it is open.
    var exactSteps: Int?
    var quality: Quality
    var savedSteps: Int?
    /// The tab that shows its progress and result.
    var tab: Tab = .image
  }


  struct VideoJob {
    var request: VideoRequest
    var suffix: String
    var fps: Int
    var format: VideoWriter.Format
  }


  func outputURL(_ fileExtension: String) -> URL {
    outDir.appendingPathComponent(Self.stampFormat.string(from: Date()) + "." + fileExtension)
  }


  var presetSuffix: String {
    presets.first(where: { $0.id == chosenPreset })?.suffix ?? ""
  }


  static func randomSeed() -> UInt32 { SeedPlan.random() }

  func enqueue() {
    guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    if let message = ModelsFolder.unavailableMessage(modelsDir) {
      status = "диск с моделями не подключён"
      notify(
        Notice(
          title: "Диск с моделями не подключён", message: message,
          actions: [.init("Диск подключён, запустить", .restartEngine)]))
      return
    }
    guard engineHost.ready else {
      status = engineHost.installed ? "движок ещё не готов" : "движок не установлен"
      notify(
        Notice(
          title: engineHost.running ? "Движок ещё запускается" : "Движок не запущен",
          message: engineHost.running
            ? "Это занимает несколько секунд. Нажмите «Сгенерировать» чуть позже"
            : "Без него изображения не считаются",
          actions: engineHost.running ? [] : [.init("Запустить движок", .restartEngine)]))
      return
    }
    if tab == .video {
      guard let job = makeVideoJob() else {
        status = "видеомодели нет"
        notify(
          Notice(
            title: "Видеомодель не выбрана",
            message: "Скачайте одну на вкладке «Каталог» — начните с Wan 2.1 1.3B",
            actions: [.init("Модели…", .openModels)]))
        return
      }
      queue.append(.video(job))
    } else if tab == .edit {
      guard let jobs = makeEditJobs() else {
        notify(
          Notice(
            title: "Нечего править",
            message: "Перетащите картинку в середину окна или выберите её слева"))
        return
      }
      queue.append(contentsOf: jobs.map(Job.image))
    } else {
      queue.append(contentsOf: makeImageJobs().map(Job.image))
    }
    assist.remember(prompt: prompt)
    queued = queue.count
    startWorker()
  }


  func makeImageJobs() -> [ImageJob] {
    if pro { commitSize() }
    let (w, h) = effectiveSize
    var inputs: [MediaGenerationPipeline.Input] = []
    for r in references {
      let file = MediaGenerationPipeline.file(r.url.path)
      switch r.role {
      case .source: inputs.append(file)
      case .mask: inputs.append(file.mask())
      case .moodboard: inputs.append(file.moodboard())
      }
    }
    let upscale = effectiveUpscale
    let base = ImageRequest(
      model: model, prompt: prompt, negative: effectiveNegative, width: w, height: h, steps: nil,
      seed: 0, cfg: effectiveCFG, sampler: effectiveSampler, loras: effectiveLoRAs,
      strength: strength, inputs: inputs, upscaler: upscale?.file,
      upscaleFactor: upscale?.factor ?? 0, parts: partsInUse(for: modelEntry),
      tweaks: tweaksInUse(for: modelEntry, masked: false), regions: regionsInUse(edit: false))
    let name = models.first(where: { $0.file == model })?.name ?? model
    // a locked seed with a batch of four still gives four different pictures (`SeedPlan`)
    let seeds = SeedPlan.seeds(count: batch, locked: seedLocked, lockedSeed: lockedSeed)
    return seeds.map { seed in
      var request = base
      request.seed = seed
      return ImageJob(
        request: request, suffix: presetSuffix, modelName: name,
        exactSteps: pro ? proSteps : nil, quality: quality, savedSteps: savedForModel?.steps)
    }
  }


  /// The edit tab's run: the picture, the painted mask, the borrowed pictures and ControlNets.
  /// nil when there is no picture to edit.
  func makeEditJobs() -> [ImageJob]? {
    guard let source = editSource else { return nil }
    if pro { commitSize() }
    let (w, h) = effectiveSize
    var inputs: [MediaGenerationPipeline.Input] = [MediaGenerationPipeline.file(source.url.path)]
    var masked = false
    // with boxes chosen instead of the mask, a mask painted earlier stays out of the run
    let boxes = regionsAvailable && regionDrawing
    if !boxes, let mask = editMask, let url = writeMask(mask, width: w, height: h) {
      inputs.append(MediaGenerationPipeline.file(url.path).mask())
      masked = true
    }
    inputs += editRefs.map { MediaGenerationPipeline.file($0.url.path).moodboard() }
    let controls = controlNetOn ? editControls(adding: &inputs) : []
    // A model that edits by instruction redraws from its references, never half-denoised;
    // any other model works as img2img, as much as the strength says.
    let upscale = effectiveUpscale
    let base = ImageRequest(
      model: model, prompt: prompt, negative: effectiveNegative, width: w, height: h, steps: nil,
      seed: 0, cfg: effectiveCFG, sampler: effectiveSampler, loras: effectiveLoRAs,
      strength: canEdit ? 1 : Float(editStrength), inputs: inputs, upscaler: upscale?.file,
      upscaleFactor: upscale?.factor ?? 0, parts: partsInUse(for: modelEntry),
      tweaks: tweaksInUse(for: modelEntry, masked: masked), controls: controls,
      regions: regionsInUse(edit: true), regionsEdit: true)
    let name = modelEntry?.name ?? model
    let seeds = SeedPlan.seeds(count: batch, locked: seedLocked, lockedSeed: lockedSeed)
    return seeds.map { seed in
      var request = base
      request.seed = seed
      return ImageJob(
        request: request, suffix: presetSuffix, modelName: name,
        exactSteps: pro ? proSteps : nil, quality: quality, savedSteps: savedForModel?.steps,
        tab: .edit)
    }
  }


  /// The picture and edit tabs each keep their own model: switching tabs puts back the one
  /// last used there. The edit tab starts on a model that edits by instruction, if any.
  func swapTabModel(from old: Tab) {
    if old == .image { imageTabModel = model }
    if old == .edit { editTabModel = model }
    let want: String
    switch tab {
    case .image: want = imageTabModel
    case .edit:
      want =
        editTabModel.isEmpty
        ? (editModels.first(where: { $0.family == "qwen_image_2.1" }) ?? editModels.first)?.file
          ?? model
        : editTabModel
    case .video: return
    }
    guard !want.isEmpty, want != model, models.contains(where: { $0.file == want }) else { return }
    selectModel(want)
  }


  func makeVideoJob() -> VideoJob? {
    guard !videoModel.isEmpty, videoFamily != nil else { return nil }
    let size = videoSize
    // Only models built to animate a picture get one; handing a frame to a text-to-video
    // model does nothing good.
    var inputs: [MediaGenerationPipeline.Input] = []
    if videoTakesImage, let first = videoFirstFrame {
      inputs.append(MediaGenerationPipeline.file(first.url.path))
      // The engine reads the first extra picture as the frame to end on. Without a first
      // frame it would take this one as the start instead, so it only goes along with one.
      if videoTakesLastFrame, let last = videoLastFrame {
        inputs.append(MediaGenerationPipeline.file(last.url.path).moodboard())
      }
    }
    let request = VideoRequest(
      model: videoModel, prompt: prompt, negative: videoNegativeOn ? videoNegative : "",
      width: size.width, height: size.height, frames: videoFrames, steps: videoSteps,
      seed: SeedPlan.single(locked: seedLocked, lockedSeed: lockedSeed), cfg: videoCFG, sampler: videoSampler,
      shift: videoShift, inputs: inputs, parts: partsInUse(for: videoEntry),
      tweaks: tweaksInUse(for: videoEntry, masked: false), refiner: videoRefinerInUse?.file,
      refinerStart: Float(videoRefinerStart),
      takesImage: takesImageOverridden ? videoTakesImage : nil)
    return VideoJob(request: request, suffix: presetSuffix, fps: videoFPS, format: videoFormat)
  }


  func startWorker() {
    guard work == nil else { return }
    runID += 1
    let id = runID
    work = Task { await drain(id) }
  }


  func cancelAll() {
    queue.removeAll()
    queued = 0
    work?.cancel()
    work = nil
    runID += 1
    busy = false
    running = nil
    stepText = ""
    livePreview = nil
    status = "отменено"
  }


  func drain(_ id: Int) async {
    busy = true
    batchGroup = []
    gridMode = false
    var failed = false
    defer {
      if id == runID {
        busy = false
        running = nil
        stepText = ""
        livePreview = nil
        work = nil
        queued = queue.count
      }
    }
    while id == runID, !Task.isCancelled, !queue.isEmpty {
      let job = queue.removeFirst()
      queued = queue.count
      let ok: Bool
      switch job {
      case .image(let job): ok = await runImage(job, id)
      case .video(let job): ok = await runVideo(job, id)
      }
      refreshMemory()
      if !ok {
        // Something broke, most often the engine itself. The rest of the queue would only
        // fail the same way, so it is dropped instead of waiting forever.
        failed = true
        if id == runID {
          queue.removeAll()
          queued = 0
        }
        break
      }
    }
    if id == runID, !failed { status = Task.isCancelled ? "отменено" : "готов" }
  }


  func progress(_ id: Int) -> @Sendable (Int, Int) -> Void {
    { [weak self] step, total in
      Task { @MainActor in
        guard let self, self.runID == id else { return }
        self.stepText = "шаг \(step) из \(total)"
        self.stepFraction = Double(step) / Double(max(1, total))
      }
    }
  }


  /// nil while the progress preview is switched off, so nothing is decoded for it.
  func preview(_ id: Int) -> (@Sendable (PreviewBox) -> Void)? {
    guard showProgressPreview else { return nil }
    return { [weak self] box in
      Task { @MainActor in
        guard let self, self.runID == id, self.showProgressPreview else { return }
        self.livePreview = NSImage(
          cgImage: box.image, size: NSSize(width: box.image.width, height: box.image.height))
      }
    }
  }


  /// Opens the job's model. Returns nil, with the user told why, when it would not open.
  func open(_ model: String, _ id: Int) async -> Recommended? {
    status = "готовлю модель"
    do {
      let r = try await engine.prepare(model: model, backend: engineHost.backend, key: engineKey)
      tweakDefaults[model] = r.defaults
      return r
    } catch {
      guard id == runID, !Task.isCancelled else { return nil }
      status = "модель не открылась: \(error.localizedDescription)"
      notify(modelFailed(error))
      return nil
    }
  }


  func failed(_ title: String, _ error: Error, _ id: Int) -> Bool {
    if error is CancellationError || Task.isCancelled || id != runID { return true }
    status = "ошибка: \(error.localizedDescription)"
    notify(
      Notice(
        title: title,
        message: Self.capitalized(error.localizedDescription),
        actions: [
          .init("Перезапустить движок", .restartEngine), .init("Освободить память", .freeMemory),
        ]))
    return false
  }


  /// One picture. Returns false only when the queue behind it should be abandoned.
  func runImage(_ job: ImageJob, _ id: Int) async -> Bool {
    running = job.tab
    livePreview = nil
    var request = job.request
    let text = await modelText(for: request.prompt)
    guard id == runID, !Task.isCancelled else { return true }
    await translator.releaseLocalModels()
    guard let r = await open(request.model, id) else { return id != runID || Task.isCancelled }
    guard id == runID, !Task.isCancelled else { return true }
    if request.model == model { recommended = r }
    request.prompt = text + job.suffix
    if !request.regions.isEmpty {
      request.prompt = RegionLayout.prompt(
        caption: request.prompt, regions: request.regions, edit: request.regionsEdit)
    }
    let steps = job.exactSteps ?? job.quality.steps(from: job.savedSteps ?? r.steps)
    request.steps = steps
    status = "считаю"
    stepText = "шаг 0 из \(steps)"
    stepFraction = 0
    let started = Date()
    let url = outputURL("png")
    let hasAlpha: Bool
    do {
      hasAlpha = try await engine.run(
        request, backend: engineHost.backend, key: engineKey, to: url,
        onStep: progress(id), onPreview: preview(id))
    } catch {
      return failed("Генерация прервалась", error, id)
    }
    // The file is on disk either way; a run that was cancelled at the very end still shows
    // what it made rather than leaving an orphan in the folder.
    guard let image = NSImage(contentsOf: url) else { return true }
    // the upscaler changes the size, so it is read off the picture itself
    let pixels =
      image.representations.first.map { ($0.pixelsWide, $0.pixelsHigh) }
      ?? (request.width, request.height)
    let frame = Frame(
      image: image, url: url, model: job.modelName, prompt: request.prompt, seed: request.seed,
      steps: steps, width: pixels.0, height: pixels.1, seconds: Date().timeIntervalSince(started),
      hasAlpha: hasAlpha)
    frames.insert(frame, at: 0)
    addStill(url)
    if job.tab == .edit {
      editResult = frame
      editShowResult = true
    }
    guard id == runID else { return true }
    livePreview = nil
    batchGroup.append(frame)
    selected = frame
    gridMode = batchGroup.count > 1
    revealHUD()
    return true
  }


  /// One clip, start to finish: the engine makes the frames, the app makes the file.
  func runVideo(_ job: VideoJob, _ id: Int) async -> Bool {
    running = .video
    livePreview = nil
    var request = job.request
    let text = await modelText(for: request.prompt)
    guard id == runID, !Task.isCancelled else { return true }
    await translator.releaseLocalModels()
    guard await open(request.model, id) != nil else { return id != runID || Task.isCancelled }
    guard id == runID, !Task.isCancelled else { return true }
    request.prompt = text + job.suffix
    status = "считаю"
    stepText = "шаг 0 из \(request.steps)"
    stepFraction = 0
    let started = Date()
    let url = outputURL(job.format.fileExtension)
    do {
      let pngs = try await engine.runVideo(
        request, backend: engineHost.backend, key: engineKey, onStep: progress(id),
        onPreview: preview(id))
      if id == runID {
        livePreview = nil
        status = "собираю файл"
        stepText = "\(pngs.count) кадров"
      }
      try await VideoWriter.write(pngs: pngs, fps: Double(job.fps), to: url, format: job.format)
      let clip = Clip(
        url: url, poster: pngs.first.flatMap { NSImage(data: $0) } ?? NSImage(),
        prompt: request.prompt, seed: request.seed, frames: pngs.count, fps: job.fps,
        width: request.width, height: request.height, steps: request.steps,
        took: Date().timeIntervalSince(started))
      clips.insert(clip, at: 0)
      if id == runID {
        show(clip)
        revealHUD()
      }
      return true
    } catch {
      return failed("Видео не собралось", error, id)
    }
  }
}
