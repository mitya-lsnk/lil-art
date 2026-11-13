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
  // MARK: recent pictures

  // MARK: recent pictures

  /// The newest pictures in the output folder, read once in the background: listing the
  /// folder and decoding even small thumbnails is not work for the main thread.
  func loadStills() async {
    let dir = outDir
    let found: [(URL, PreviewBox)] = await Task.detached(priority: .utility) {
      let manager = FileManager.default
      guard
        let files = try? manager.contentsOfDirectory(
          at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
      else { return [] }
      return
        files
        .filter { ["png", "jpg", "jpeg", "heic", "webp"].contains($0.pathExtension.lowercased()) }
        .map {
          (
            $0,
            (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
              .contentModificationDate ?? .distantPast
          )
        }
        .sorted { $0.1 > $1.1 }
        .prefix(Self.stillCount)
        .compactMap { url, _ in Thumbnail.cgImage(url, maxPixel: 256).map { (url, PreviewBox($0)) } }
    }.value
    let known = Set(recentStills.map(\.url))
    recentStills += found.filter { !known.contains($0.0) }.map { url, box in
      Still(url: url, thumb: NSImage(cgImage: box.image, size: NSSize(width: box.image.width, height: box.image.height)))
    }
    if recentStills.count > Self.stillCount { recentStills.removeLast(recentStills.count - Self.stillCount) }
  }


  nonisolated static let stillCount = 12

  func addStill(_ url: URL) {
    guard let thumb = Thumbnail.make(url, maxPixel: 256) else { return }
    recentStills.removeAll { $0.url == url }
    recentStills.insert(Still(url: url, thumb: thumb), at: 0)
    if recentStills.count > Self.stillCount { recentStills.removeLast() }
  }


  /// A vertical photo should not quietly become a wide clip with the sides cut off, so
  /// the size that fits it best is picked as soon as the picture arrives.
  func matchSize(to image: NSImage) {
    guard let rep = image.representations.first, rep.pixelsHigh > 0 else { return }
    let ratio = Double(rep.pixelsWide) / Double(rep.pixelsHigh)
    var best = 0
    var gap = Double.infinity
    for (index, size) in videoSizes.enumerated() {
      let distance = abs(Double(size.width) / Double(size.height) - ratio)
      if distance < gap {
        gap = distance
        best = index
      }
    }
    videoSizeIndex = best
  }


  /// Clips already in the output folder. Without this the app forgets every video the
  /// moment it quits, while the files sit there in plain sight.
  func loadClips() async {
    let manager = FileManager.default
    guard
      let files = try? manager.contentsOfDirectory(
        at: outDir, includingPropertiesForKeys: [.contentModificationDateKey])
    else { return }
    let videos =
      files
      .filter { ["mp4", "mov"].contains($0.pathExtension.lowercased()) }
      .sorted {
        let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
          .contentModificationDate ?? .distantPast
        let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?
          .contentModificationDate ?? .distantPast
        return left > right
      }
      .prefix(24)

    var found: [Clip] = []
    for url in videos {
      let asset = AVURLAsset(url: url)
      guard let track = try? await asset.loadTracks(withMediaType: .video).first,
        let duration = try? await asset.load(.duration),
        let size = try? await track.load(.naturalSize),
        let rate = try? await track.load(.nominalFrameRate)
      else { continue }
      let generator = AVAssetImageGenerator(asset: asset)
      generator.appliesPreferredTrackTransform = true
      let poster = (try? await generator.image(at: .zero).image).map {
        NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height))
      }
      let seconds = CMTimeGetSeconds(duration)
      let fps = rate > 0 ? Double(rate) : 16
      found.append(
        Clip(
          url: url, poster: poster ?? NSImage(), prompt: "", seed: 0,
          frames: max(1, Int((seconds * fps).rounded())), fps: Int(fps.rounded()),
          width: Int(size.width), height: Int(size.height), steps: 0, took: 0, restored: true))
    }
    // a clip made while the folder was being read is already in the list and stays first
    let known = Set(clips.map(\.url))
    clips += found.filter { !known.contains($0.url) }
    if selectedClip == nil, let first = clips.first { show(first) }
  }


  /// Puts a clip on the stage and loops it, the way a short is meant to be watched.
  func show(_ clip: Clip) {
    selectedClip = clip
    clipLooper?.disableLooping()
    clipPlayer.removeAllItems()
    clipLooper = AVPlayerLooper(player: clipPlayer, templateItem: AVPlayerItem(url: clip.url))
    if tab == .video { clipPlayer.play() } else { clipPlayer.pause() }
  }


  func selectVideoModel(_ file: String) {
    guard videoModel != file else { return }
    videoModel = file
    videoModelChanged()
  }


  /// A new video model brings its own frame rate, its own sizes and its own idea of how
  /// many steps are enough. Carrying the previous model's numbers over is how people end
  /// up with fog.
  func videoModelChanged() {
    guard let entry = videoEntry, let family = VideoFamily.of(entry.family) else { return }
    let profile = SpeedPrefs.profile(file: entry.file, name: entry.name)
    if tab == .video { speedProfile = profile }
    restoreRefiner(for: entry)
    videoFPS = family.fps
    videoShift = family.shift
    videoSizeIndex = 0
    videoCustomSize = nil
    videoSeconds = min(videoSeconds, family.maxSeconds)
    videoSteps = profile.steps(for: family)
    videoCFG = profile.cfg(for: family)
    let wanted = videoModel
    Task { [weak self] in
      guard let self, self.engineHost.ready else { return }
      do {
        let r = try await self.engine.prepare(
          model: wanted, backend: self.engineHost.backend, key: self.engineKey)
        self.tweakDefaults[wanted] = r.defaults
        guard self.videoModel == wanted else { return }
        // The engine ships a recommendation with every catalog model, and it is better
        // informed than any guess made from the file name — including about whether this
        // is a distilled model at all.
        if SpeedPrefs.stored(wanted) == nil, self.tab == .video {
          self.speedProfile = r.steps <= 12 ? .fast : .full
        }
        self.videoSteps = r.steps
        self.videoCFG = r.cfg
        self.videoSampler = r.sampler
      } catch {
        guard self.videoModel == wanted else { return }
        self.status = "модель не открылась: \(error.localizedDescription)"
        self.notify(self.modelFailed(error))
      }
    }
  }


  /// The profile belongs to a model, and each tab has its own model.
  func refreshSpeedProfile() {
    let file = tab == .video ? videoModel : model
    guard !file.isEmpty else { return }
    let name = library.checkpoints.first(where: { $0.file == file })?.name ?? file
    speedProfile = SpeedPrefs.profile(file: file, name: name)
  }


  /// The fast/full switch, and what it does to the numbers.
  func setSpeed(_ profile: SpeedProfile) {
    speedProfile = profile
    SpeedPrefs.save(profile, for: videoModel)
    videoSteps = profile.steps(for: videoFamily)
    videoCFG = profile.cfg(for: videoFamily)
  }


  /// What the next clip will cost. Frames multiply everything, which is exactly what
  /// people are surprised by the first time.
  var videoTimeEstimate: String {
    let size = videoSize
    let one = Budget.seconds(width: size.width, height: size.height, steps: videoSteps)
    // Every frame goes through the model on every step, but they share one pass, so the
    // cost grows with frames rather than multiplying by them outright.
    return Budget.humanTime(one * (1 + Double(videoFrames - 1) * 0.55))
  }

  var videoMemoryGB: Double {
    let size = videoSize
    // the engine unloads the first expert before the second: the larger one is what counts
    let model = Double(max(videoEntry?.bytes ?? 0, videoRefinerInUse?.bytes ?? 0)) / 1_073_741_824
    return model + Budget.perMegapixelGB * size.megapixels * Double(videoFrames) * 0.18 + 1.5
  }


  /// A model that has just finished importing: a checkpoint becomes the selection unless a
  /// picture is being made, a LoRA goes straight into the LoRA block.
  func adopt(_ item: InstalledModel) {
    switch item.role {
    case .checkpoint:
      if VideoFamily.isVideo(item.family) {
        if running != .video { selectVideoModel(item.file) }
      } else if running != .image {
        selectModel(item.file)
      }
      status = "модель готова: \(item.name)"
    case .lora:
      if !loraPicks.contains(where: { $0.file == item.file }) {
        loraPicks.append(LoRAPick(file: item.file))
      }
      loraOn = true
      status = "LoRA готова: \(item.name)"
    case .upscaler:
      status = "Upscaler готов: \(item.name)"
    case .part:
      // added to be used: the selected models it fits switch to it right away
      guard let part = item.part else { return }
      var switched: [String] = []
      for entry in [modelEntry, videoEntry].compactMap({ $0 }) where entry.parts[part.slot].map(part.fits) == true {
        choosePart(item.file, part.slot, for: entry)
        switched.append(entry.name)
      }
      status =
        switched.isEmpty
        ? "\(part.slot.title) готов: \(item.name)"
        : "\(part.slot.title) «\(item.name)» включён для \(switched.joined(separator: " и "))"
    }
  }


  func restartEngine() {
    guard !busy else {
      status = "дождитесь конца генерации"
      return
    }
    Task {
      await engine.release()
      engineHost.stop()
      try? await Task.sleep(nanoseconds: 500_000_000)
      // a disk plugged in since the launch: its models are listed again
      library.rescan()
      engineHost.start(modelsDir: modelsDir)
    }
  }


  /// Downloads and installs the newest engine without pulling it out from under a run.
  func updateEngine() async {
    guard !busy, queue.isEmpty else {
      status = "дождитесь конца генерации"
      return
    }
    guard !engineHost.busy else { return }
    await engine.release()
    let wasRunning = engineHost.running
    engineHost.stop()
    await engineHost.install()
    if wasRunning || engineHost.installed { engineHost.start(modelsDir: modelsDir) }
  }


  /// The engine takes its memory setting when it starts, so a change restarts it.
  func applyCache(_ gb: Double) {
    guard gb != cacheGB else { return }
    setCache(gb)
    if engineHost.running { restartEngine() }
  }


  func engineHooks() -> EngineHooks {
    let wasRunning = engineHost.running
    return EngineHooks(
      pause: { [weak self] in await self?.pauseEngine() },
      resume: { [weak self] made, replacing in
        await self?.resumeEngine(selecting: made, replacing: replacing, wasRunning: wasRunning)
      },
      waitIdle: { [weak self] in
        while let self, self.busy || !self.queue.isEmpty, !Task.isCancelled {
          try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
      })
  }


  func pauseEngine() async {
    await engine.release()
    engineHost.stop()
    status = "движок на паузе: конвертирую модель"
  }


  func resumeEngine(selecting made: String?, replacing: String?, wasRunning: Bool) async {
    // a compressed copy takes over only if its original was the one in use
    let follow = replacing == nil || model == replacing
    library.rescan()
    if let made, follow, library.checkpoints.contains(where: { $0.file == made }) { model = made }
    // the engine reads the list of converted models only when it starts
    if wasRunning || made != nil {
      try? await Task.sleep(nanoseconds: 1_000_000_000)
      engineHost.start(modelsDir: modelsDir)
      for _ in 0..<40 {
        if engineHost.ready || !engineHost.running { break }
        try? await Task.sleep(nanoseconds: 500_000_000)
      }
    }
    status = "готов"
    modelChanged()
  }


  // MARK: settings saved per model

  func forgetForModel() {
    ModelPrefs.save(nil, for: model)
    savedForModel = nil
    if let r = recommended {
      proSteps = r.steps
      proCFG = r.cfg
      sampler = r.sampler
    }
    status = "снова как советует модель"
  }


  // MARK: the session, kept across launches

  // MARK: the session, kept across launches

  struct Session: Codable {
    var prompt: String
    var negative: String
    var negativeOn: Bool
    var model: String
    var pro: Bool
    var aspect: String
    var megapixels: Double
    var quality: String
    var batch: Int
    var preset: String?
    var sampler: Int
    var steps: Int
    var cfg: Float
    var width: Int
    var height: Int
    var showSizePad: Bool
    var seedLocked: Bool
    var seed: UInt32
    var loraOn: Bool
    var loras: [String]
    var loraWeights: [Double]
    var strength: Float
    var upscaleOn: Bool?
    var upscaler: String?
    var upscaleFactor: Int?
    // Everything below arrived with the video tab, so it is optional: sessions saved by
    // an older build decode without it.
    var videoTab: Bool?
    var videoModel: String?
    var videoSeconds: Double?
    var videoSizeIndex: Int?
    var videoSteps: Int?
    var videoCFG: Float?
    var videoShift: Float?
    var videoFPS: Int?
    var videoSampler: Int?
    var videoPro: Bool?
    var videoNegativeOn: Bool?
    var videoNegative: String?
  }


  func saveSession() {
    guard restoreSession else { return }
    let session = Session(
      prompt: prompt, negative: negative, negativeOn: negativeOn, model: model, pro: pro,
      aspect: aspect.rawValue, megapixels: megapixels.rawValue, quality: quality.rawValue,
      batch: batch, preset: presets.first(where: { $0.id == chosenPreset })?.name,
      sampler: Int(sampler.rawValue), steps: proSteps, cfg: proCFG, width: proWidth,
      height: proHeight, showSizePad: showSizePad, seedLocked: seedLocked, seed: lockedSeed,
      loraOn: loraOn, loras: loraPicks.map(\.file), loraWeights: loraPicks.map(\.weight),
      strength: strength, upscaleOn: upscaleOn, upscaler: upscaler, upscaleFactor: upscaleFactor,
      videoTab: tab == .video, videoModel: videoModel, videoSeconds: videoSeconds,
      videoSizeIndex: videoSizeIndex, videoSteps: videoSteps, videoCFG: videoCFG,
      videoShift: videoShift, videoFPS: videoFPS, videoSampler: Int(videoSampler.rawValue),
      videoPro: videoPro, videoNegativeOn: videoNegativeOn, videoNegative: videoNegative)
    // The saver fires on every change anywhere in the window; most of the time nothing
    // in the session moved, and rewriting the same bytes is pure waste.
    if let data = try? JSONEncoder().encode(session), data != lastSavedSession {
      LilStore.standard.set(data, forKey: "session.last")
      lastSavedSession = data
    }
  }


  /// As much as can be kept without starving the system: everything but 6 GB.
  var maxCacheGB: Double { max(4, (Mem.machineGB - 6).rounded(.down)) }
  var modelBytes: Int64 { library.installed.first { $0.file == model }?.bytes ?? 0 }

  func flipAspect() { aspect = aspect.flipped }

  /// Stands the frame on its end without hunting for the value on the pad again.
  func swapSize() {
    let w = proWidth
    proWidth = proHeight
    proHeight = w
    widthText = String(proWidth)
    heightText = String(proHeight)
  }


  func addReference() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.image]
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = true
    panel.message = "выберите изображение"
    guard panel.runModal() == .OK else { return }
    panel.urls.forEach(addReference)
  }


  func addReference(_ url: URL) {
    guard let thumb = Thumbnail.make(url) else { return }
    let role: RefRole = references.contains(where: { $0.role == .source }) ? .moodboard : .source
    references.append(Reference(url: url, role: role, thumb: thumb))
  }


  /// A picture dropped anywhere on the window goes where the open tab wants pictures.
  func acceptDropped(_ url: URL) {
    switch tab {
    case .image: addReference(url)
    case .edit:
      if editSource == nil { setEditSource(url) } else { addEditRef(url) }
    case .video: setFrame(url, .first)
    }
  }


  func removeReference(_ r: Reference) {
    references.removeAll { $0.id == r.id }
  }


  func setRole(_ r: Reference, _ role: RefRole) {
    guard let i = references.firstIndex(where: { $0.id == r.id }) else { return }
    references[i].role = role
  }


  var hasSourceImage: Bool { references.contains { $0.role == .source } }

  /// The same strip for the video tab.
  var videoRunLine: String {
    var parts = [
      "\(videoSize.width) × \(videoSize.height)", videoLengthLabel, "Steps \(videoSteps)",
      String(format: "CFG %.1f", videoCFG),
    ]
    if videoPro { parts.append(Samplers.name(videoSampler)) }
    parts += partsLabel(for: videoEntry)
    if let low = videoRefinerInUse {
      let split = refinerSplit
      parts.append("+ \(low.name): high \(split.high) · low \(split.low) шагов")
    }
    parts.append(seedLocked ? "Seed \(lockedSeed)" : "Seed случайный")
    if videoTakesImage, videoFirstFrame != nil {
      parts.append(
        videoTakesLastFrame && videoLastFrame != nil ? "с первым и последним кадром" : "с первым кадром")
    }
    return parts.joined(separator: "  ·  ")
  }


  /// Everything the run will use, for the strip along the bottom of the window.
  var runLine: String {
    var parts = [
      sizeLabel, "Steps \(effectiveSteps ?? recommended?.steps ?? 4)",
      String(format: "CFG %.1f", effectiveCFG ?? recommended?.cfg ?? 3.5),
    ]
    if pro { parts.append(Samplers.name(sampler)) }
    if let picks = effectiveLoRAs { parts.append("LoRA: \(picks.count)") }
    if effectiveUpscale != nil { parts.append("Upscale ×\(effectiveFactor)") }
    parts += partsLabel(for: modelEntry)
    parts.append(seedLocked ? "Seed \(lockedSeed)" : "Seed случайный")
    if batch > 1 { parts.append("× \(batch)") }
    if !references.isEmpty {
      parts.append("изображений на входе: \(references.count)")
      if hasSourceImage { parts.append(String(format: "Denoise %.2f", strength)) }
    }
    return parts.joined(separator: "  ·  ")
  }


  func openOutputFolder() { NSWorkspace.shared.open(outDir) }

  func reveal(_ frame: Frame) {
    NSWorkspace.shared.activateFileViewerSelecting([frame.url])
  }


  /// Runs every two seconds. Every published change redraws the whole window, so the
  /// numbers are only handed over when they moved enough to show.
  func refreshMemory() {
    let used = Mem.footprintGB()
    let free = Mem.systemAvailableGB()
    if abs(used - footprint) >= 0.05 { footprint = used }
    if abs(free - systemFree) >= 0.05 { systemFree = free }
    monitor.sample(enginePID: engineHost.pid)
  }
}
