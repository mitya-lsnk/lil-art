import AppKit
import CoreGraphics
import Foundation
import ImageIO
import MediaGenerationKit
import UniformTypeIdentifiers

/// The edit tab's working parts: the mask, ControlNets, saved phrases, and the finer settings
/// every tab shares.
@available(macOS 26, *)
extension Studio {
  // MARK: mask

  /// Writes the mask the engine reads: the size of the run, laid over the picture the same way
  /// the kit lays the picture (filled, centred), and with only two values — 0 keep, 2 redraw
  /// as strongly as the strength says (1: from pure noise). Drawing it at the run's size
  /// without smoothing matters: the kit would scale a mask smoothly, and the in-between
  /// values on the edge mean "pure noise", a ring of mess around every stroke.
  func writeMask(_ mask: CGImage, width: Int, height: Int) -> URL? {
    guard width > 0, height > 0, let painted = Self.grayPixels(of: mask) else { return nil }
    guard painted.pixels.contains(where: { $0 >= 128 }) else { return nil }
    let sw = painted.width
    let sh = painted.height
    // the same arithmetic as the kit's ImageConverter.resize
    let scaledWidth: Int
    let scaledHeight: Int
    if sw * height > sh * width {
      scaledHeight = height
      scaledWidth = sw * height / sh
    } else {
      scaledWidth = width
      scaledHeight = sh * width / sw
    }
    let offsetX = (width - scaledWidth) / 2
    let offsetY = (height - scaledHeight) / 2
    let redraw: UInt8 = maskFresh ? 1 : 2
    var out = [UInt8](repeating: 0, count: width * height)
    for y in 0..<height {
      let sy = min(sh - 1, max(0, (y - offsetY) * sh / max(1, scaledHeight)))
      for x in 0..<width {
        let sx = min(sw - 1, max(0, (x - offsetX) * sw / max(1, scaledWidth)))
        if painted.pixels[sy * sw + sx] >= 128 { out[y * width + x] = redraw }
      }
    }
    // three equal channels: the kit reads the grey level straight through
    var rgb = [UInt8](repeating: 0, count: width * height * 3)
    for i in 0..<(width * height) {
      rgb[i * 3] = out[i]
      rgb[i * 3 + 1] = out[i]
      rgb[i * 3 + 2] = out[i]
    }
    let dir = ProjectRoot.places.cache.appendingPathComponent("masks")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    // old masks are only ever read by the run they were made for
    if let old = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
      for url in old { try? FileManager.default.removeItem(at: url) }
    }
    let url = dir.appendingPathComponent(UUID().uuidString + ".png")
    guard let provider = CGDataProvider(data: Data(rgb) as CFData),
      let image = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24,
        bytesPerRow: width * 3, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
        decode: nil, shouldInterpolate: false, intent: .defaultIntent),
      let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination) ? url : nil
  }

  nonisolated static func grayPixels(of image: CGImage) -> (pixels: [UInt8], width: Int, height: Int)? {
    let width = image.width
    let height = image.height
    guard width > 0, height > 0 else { return nil }
    var pixels = [UInt8](repeating: 0, count: width * height)
    let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
      guard
        let context = CGContext(
          data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
          bitmapInfo: CGImageAlphaInfo.none.rawValue)
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    return drawn ? (pixels, width, height) : nil
  }

  var maskIsEmpty: Bool { !maskPainted }

  nonisolated static func hasPaint(_ mask: CGImage) -> Bool {
    guard let painted = grayPixels(of: mask) else { return false }
    return painted.pixels.contains { $0 >= 128 }
  }

  func clearMask() { editMask = nil }

  /// Swaps painted and untouched: paint the thing to keep, then invert.
  func invertMask() {
    guard let source = editSource, let size = Self.pixelSize(of: source.url) else { return }
    let width = size.width
    let height = size.height
    var pixels = [UInt8](repeating: 255, count: width * height)
    if let mask = editMask, let painted = Self.grayPixels(of: mask),
      painted.width == width, painted.height == height
    {
      pixels = painted.pixels.map { $0 >= 128 ? 0 : 255 }
    }
    editMask = Self.grayImage(pixels, width: width, height: height)
  }

  static func grayImage(_ pixels: [UInt8], width: Int, height: Int) -> CGImage? {
    guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
    return CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
  }

  /// The picture's size in pixels, read from its header; the mask is kept at this size,
  /// capped so a huge photo does not make a huge mask.
  static func pixelSize(of url: URL) -> (width: Int, height: Int)? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let w = props[kCGImagePropertyPixelWidth] as? Int,
      let h = props[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0
    else { return nil }
    let scale = min(1, 2048 / Double(max(w, h)))
    return (max(1, Int(Double(w) * scale)), max(1, Int(Double(h) * scale)))
  }

  /// The latest result becomes the picture to edit, for another round.
  func useResultAsSource() {
    guard let frame = editResult else { return }
    setEditSource(frame.url)
  }

  // MARK: saved phrases

  func savePhrase() {
    let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, !editPhrases.contains(text) else { return }
    editPhrases.append(text)
  }

  func removePhrase(_ phrase: String) { editPhrases.removeAll { $0 == phrase } }

  // MARK: ControlNet

  var controlItems: [ControlNetItem] {
    guard let family = modelEntry?.family, !family.isEmpty else { return [] }
    return ControlNets.items(for: family)
  }

  func addControl() {
    guard let first = controlItems.first(where: { ControlNets.isOnDisk($0.file, in: modelsDir) })
      ?? controlItems.first
    else { return }
    controlPicks.append(ControlPick(file: first.file))
    controlNetOn = true
  }

  func removeControl(_ pick: ControlPick) { controlPicks.removeAll { $0.id == pick.id } }

  func updateControl(_ pick: ControlPick) {
    guard let index = controlPicks.firstIndex(where: { $0.id == pick.id }) else { return }
    controlPicks[index] = pick
  }

  func controlItem(_ pick: ControlPick) -> ControlNetItem? {
    controlItems.first { $0.file == pick.file }
  }

  /// What a pick reads, after the union kind's own choice.
  func controlHint(_ pick: ControlPick) -> String {
    guard let item = controlItem(pick) else { return "custom" }
    return item.union ? pick.unionHint : (item.hint ?? "custom")
  }

  /// Files still missing for this pick: the ControlNet and whatever makes its input.
  func missingFiles(_ pick: ControlPick) -> [String] {
    guard let item = controlItem(pick) else { return [] }
    var files = item.files
    let hint = controlHint(pick)
    files += ControlNets.helpers(for: hint, in: modelsDir)
    if hint == "depth", pick.picture == nil { files.append(ControlNets.depthModel) }
    return files.filter { !ControlNets.isOnDisk($0, in: modelsDir) }
  }

  func downloadControl(_ pick: ControlPick) {
    let files = missingFiles(pick)
    guard !files.isEmpty else { return }
    let dir = modelsDir
    Task {
      for file in files where controlDownloads[file] == nil {
        controlDownloads[file] = 0
        do {
          try await ControlNets.fetch(file, into: dir) { fraction in
            self.controlDownloads[file] = fraction
          }
          controlDownloads[file] = nil
          status = "скачан \(file)"
        } catch {
          controlDownloads[file] = nil
          notify(
            Notice(
              title: "Не скачалось",
              message: "\(file): \(error.localizedDescription)"))
          return
        }
      }
      objectWillChange.send()
    }
  }

  /// The ControlNets ready to run, with their control pictures added to the inputs.
  func editControls(adding inputs: inout [MediaGenerationPipeline.Input]) -> [Control] {
    var controls: [Control] = []
    var files: [String] = []
    for pick in controlPicks where missingFiles(pick).isEmpty {
      guard let item = controlItem(pick) else { continue }
      let hint = controlHint(pick)
      switch ControlNets.input(for: hint) {
      case .picture(let name):
        // nothing to read without the ready picture
        guard let picture = pick.picture else { continue }
        inputs.append(MediaGenerationPipeline.file(picture.url.path).hint(name))
      case .depth:
        if let picture = pick.picture {
          inputs.append(MediaGenerationPipeline.file(picture.url.path).depth())
        }
      case .source, .references:
        break
      }
      let override =
        item.union
        ? (ControlInputType.allCases.first { "\($0)" == hint } ?? .unspecified) : .unspecified
      controls.append(
        Control(
          file: item.file, weight: Float(pick.weight), guidanceStart: Float(pick.start),
          guidanceEnd: Float(pick.end), inputOverride: override))
      files.append(item.file)
    }
    ControlNets.prime(files)
    return controls
  }

  func setControlPicture(_ pick: ControlPick, _ url: URL?) {
    var changed = pick
    changed.picture = url.flatMap { url in
      Thumbnail.make(url).map { Reference(url: url, role: .moodboard, thumb: $0) }
    }
    updateControl(changed)
  }

  // MARK: finer settings

  func traits(for entry: InstalledModel?, masked: Bool) -> ModelTraits? {
    guard let entry, !entry.family.isEmpty else { return nil }
    let video = VideoFamily.isVideo(entry.family)
    return ModelTraits(
      file: entry.file, family: entry.family, video: video, masked: masked,
      sampler: video ? videoSampler : (pro ? sampler : recommended?.sampler))
  }

  func tweakDefault(_ tweak: Tweak, for entry: InstalledModel) -> Double? {
    tweakDefaults[entry.file]?[tweak.id]
  }

  func tweakValue(_ tweak: Tweak, for entry: InstalledModel) -> Double {
    TweakPrefs.stored(entry.file)[tweak.id] ?? tweakDefault(tweak, for: entry) ?? 0
  }

  func isTweakChanged(_ tweak: Tweak, for entry: InstalledModel) -> Bool {
    TweakPrefs.stored(entry.file)[tweak.id] != nil
  }

  func setTweak(_ tweak: Tweak, _ value: Double, for entry: InstalledModel) {
    objectWillChange.send()
    // back at the model's own value it is no longer a change
    let same = tweakDefault(tweak, for: entry).map { abs($0 - value) < 1e-6 } ?? false
    TweakPrefs.save(same ? nil : value, tweak.id, for: entry.file)
  }

  func resetTweaks(for entry: InstalledModel) {
    objectWillChange.send()
    TweakPrefs.clear(entry.file)
  }

  /// The changed values that mean something for this model and run.
  func tweaksInUse(for entry: InstalledModel?, masked: Bool) -> [String: Double] {
    guard let entry, let traits = traits(for: entry, masked: masked) else { return [:] }
    let stored = TweakPrefs.stored(entry.file)
    var out: [String: Double] = [:]
    for tweak in Tweaks.visible(for: traits) {
      if let value = stored[tweak.id] { out[tweak.id] = value }
    }
    return out
  }

  // MARK: settings from elsewhere

  /// Puts settings found in a picture or on Civitai onto the open tab: prompt, steps, CFG,
  /// sampler, seed, size, strength, clip skip, shift. Returns what was taken, for the notice.
  @discardableResult
  func apply(_ found: FoundSettings, takePrompt: Bool = true) -> [String] {
    if tab == .video { return applyToVideo(found, takePrompt: takePrompt) }
    var taken: [String] = []
    if !pro { pro = true }  // the exact numbers live in PRO; switching it on first keeps them
    if takePrompt, let p = found.prompt, !p.isEmpty {
      prompt = p
      taken.append("промпт")
    }
    if takePrompt, let n = found.negative, !n.isEmpty {
      negative = n
      negativeOn = true
      taken.append("негатив")
    }
    if let steps = found.steps, steps > 0 {
      proSteps = min(150, steps)
      taken.append("шаги \(steps)")
    }
    if let cfg = found.cfg {
      proCFG = Float(cfg)
      taken.append(String(format: "CFG %.1f", cfg))
    }
    let flow = !(traits(for: modelEntry, masked: false)?.unet ?? false)
    if let type = SettingsImport.samplerType(found.sampler, scheduler: found.scheduler, flow: flow) {
      sampler = type
      let original = [found.sampler, found.scheduler].compactMap { $0 }.joined(separator: " / ")
      taken.append("сэмплер \(Samplers.name(type))" + (original.isEmpty ? "" : " (было \(original))"))
    }
    if let seed = found.seed {
      lockedSeed = seed
      seedLocked = true
      taken.append("seed \(seed)")
    }
    if let w = found.width, let h = found.height, w > 0, h > 0 {
      // the engine takes multiples of 64
      let rw = max(64, Int((Double(w) / 64).rounded()) * 64)
      let rh = max(64, Int((Double(h) / 64).rounded()) * 64)
      proWidth = rw
      proHeight = rh
      widthText = String(rw)
      heightText = String(rh)
      taken.append("размер \(rw)×\(rh)")
    }
    if let strength = found.strength, strength > 0, strength < 1 {
      if tab == .edit { editStrength = strength } else { self.strength = Float(strength) }
      taken.append(String(format: "сила %.2f", strength))
    }
    if let entry = modelEntry {
      if let clip = found.clipSkip, clip > 1,
        let tweak = Tweaks.all.first(where: { $0.id == "clipSkip" }),
        traits(for: entry, masked: false).map(tweak.applies) == true
      {
        setTweak(tweak, Double(clip), for: entry)
        taken.append("clip skip \(clip)")
      }
      if let shift = found.shift, let tweak = Tweaks.all.first(where: { $0.id == "shift" }),
        traits(for: entry, masked: false).map(tweak.applies) == true
      {
        setTweak(tweak, shift, for: entry)
        taken.append(String(format: "shift %.2f", shift))
      }
    }
    return taken
  }

  /// A picture dropped into the sheet: its own metadata first, and for a Civitai picture whose
  /// file came stripped, the settings Civitai keeps for it.
  func settings(fromPicture url: URL, original: URL? = nil) async -> FoundSettings? {
    if let found = SettingsImport.read(url), !found.isEmpty { return found }
    if let original, let id = SettingsImport.civitaiImageID(original) {
      return try? await SettingsImport.civitaiImage(id)
    }
    return nil
  }

  // MARK: fitting the size

  /// The picture a run takes its shape from: the one being edited, or the picture tab's first
  /// input picture.
  var pictureToFit: URL? {
    switch tab {
    case .edit: return editSource?.url
    case .image: return references.first?.url
    case .video: return nil
    }
  }

  /// Width and height in 64-pixel steps with the picture's own shape and about as many pixels
  /// as the chosen size class gives (the model's comfortable size), so a 16:7 picture gets
  /// 1536×640, not a square or a guess.
  func fitSizeToPicture() {
    guard let url = pictureToFit else { return }
    fitSize(toPictureAt: url)
  }

  /// The run's size becomes the picture's own (896×1152 stays 896×1152), so nothing is cropped
  /// or stretched without being asked. Exact sizes live in PRO; switching it on first keeps them.
  func fitSize(toPictureAt url: URL) {
    guard let pixels = RegionLayout.pixelSize(url), pixels.width > 0, pixels.height > 0,
      let best = SizeFit.nearSource(width: Int(pixels.width), height: Int(pixels.height))
    else {
      status = "размер картинки не прочитался"
      return
    }
    if !pro { pro = true }
    proWidth = best.width
    proHeight = best.height
    widthText = String(best.width)
    heightText = String(best.height)
    status = "размер \(best.width)×\(best.height) — по картинке \(Int(pixels.width))×\(Int(pixels.height))"
  }

  /// A warning for the edit tab when the size set is another shape than the picture's.
  var editShapeWarning: String? {
    guard tab == .edit, let url = editSource?.url, let pixels = RegionLayout.pixelSize(url) else { return nil }
    let (w, h) = effectiveSize
    guard SizeFit.shapesDiffer(picture: (Int(pixels.width), Int(pixels.height)), run: (w, h)) else { return nil }
    return "форма \(w)×\(h) не такая, как у картинки \(Int(pixels.width))×\(Int(pixels.height)): края обрежутся или картинку растянет. «По картинке» вернёт её размер"
  }

  // MARK: the models folder itself

  /// Puts lil art on another models folder, carrying the models over first when asked. Every
  /// file is copied whole and checked before its original goes; a link (a model already on an
  /// external disk) moves as a link. The new folder takes effect on a restart.
  func changeModelsFolder(to target: URL, carry: Bool) {
    let source = modelsDir.standardizedFileURL
    let destination = target.standardizedFileURL
    guard source.path != destination.path else { return }
    guard carry else {
      ModelsFolder.setURL(destination)
      relaunch()
      return
    }
    folderMove = 0
    folderMoveNote = "останавливаю движок"
    engineHost.stop()
    Task {
      let result: String? = await Task.detached(priority: .utility) { () -> String? in
        let fm = FileManager.default
        do {
          try fm.createDirectory(at: destination, withIntermediateDirectories: true)
          let items = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
          func size(_ url: URL) -> Int64 {
            ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
          }
          let total = max(1, items.filter { ModelMover.linkTarget($0) == nil }.reduce(0) { $0 + size($1) })
          var done: Int64 = 0
          for item in items {
            let goal = destination.appendingPathComponent(item.lastPathComponent)
            if let link = ModelMover.linkTarget(item) {
              try? fm.removeItem(at: goal)
              try fm.createSymbolicLink(at: goal, withDestinationURL: link)
              try fm.removeItem(at: item)
              continue
            }
            var isDirectory: ObjCBool = false
            fm.fileExists(atPath: item.path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
              try fm.moveItem(at: item, to: goal)
              continue
            }
            let bytes = size(item)
            // already there whole from an earlier, interrupted move
            if size(goal) != bytes || !fm.fileExists(atPath: goal.path) {
              try ModelMover.copy(item, to: goal, progress: { chunk in
                done += chunk
                let fraction = Double(done) / Double(total)
                Task { @MainActor in self.folderMove = fraction }
              }, shouldStop: { false })
            } else {
              done += bytes
            }
            guard size(goal) == bytes else {
              throw ModelMover.Failure.mismatch(item.lastPathComponent)
            }
            try fm.removeItem(at: item)
            let name = item.lastPathComponent
            Task { @MainActor in self.folderMoveNote = "перенесён \(name)" }
          }
          return nil
        } catch {
          return ImportRunner.explain(error)
        }
      }.value
      if let result {
        folderMove = nil
        folderMoveNote = ""
        engineHost.start(modelsDir: modelsDir)
        notify(
          Notice(
            title: "Папку моделей перенести не удалось",
            message: Self.capitalized(result) + ". Перенесённое уже лежит в новой папке; можно повторить"))
        return
      }
      ModelsFolder.setURL(destination)
      folderMoveNote = "готово, перезапускаю"
      relaunch()
    }
  }

  /// A fresh copy of the app starts, this one quits: the models folder is read once, at start.
  func relaunch() {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
      DispatchQueue.main.async { NSApp.terminate(nil) }
    }
  }

  // MARK: Wan 2.2: two experts

  /// Models that can follow the chosen one: video models of the same family.
  var videoRefinerChoices: [InstalledModel] {
    guard let entry = videoEntry, !entry.family.isEmpty else { return [] }
    return videoModels.filter { $0.file != entry.file && $0.family == entry.family }
  }

  var videoRefinerInUse: InstalledModel? {
    guard !videoRefiner.isEmpty else { return nil }
    return videoRefinerChoices.first { $0.file == videoRefiner }
  }

  /// "…High…" and "…Low…" (or HNE and LNE) are one pair: the same name with that word swapped.
  private static let pairWords: [(high: String, low: String)] = [
    ("high", "low"), ("hne", "lne"), ("high_noise", "low_noise"), ("highnoise", "lownoise"),
  ]

  private static func pairKey(_ text: String, side: KeyPath<(high: String, low: String), String>) -> String? {
    // the precision ending may differ between the two (one squeezed to 6 bits, one to 8)
    let lower = text.lowercased().replacingOccurrences(
      of: #"(_(f16|q[4-8]p|i[3-8]x))*(_svd)?\.ckpt$"#, with: "", options: .regularExpression)
    for words in pairWords where lower.contains(words[keyPath: side]) {
      return lower.replacingOccurrences(of: words[keyPath: side], with: "#")
    }
    return nil
  }

  func isHighExpert(_ entry: InstalledModel) -> Bool {
    Self.pairKey(entry.file, side: \.high) != nil || Self.pairKey(entry.name, side: \.high) != nil
  }

  func isLowExpert(_ entry: InstalledModel) -> Bool {
    Self.pairKey(entry.file, side: \.low) != nil || Self.pairKey(entry.name, side: \.low) != nil
  }

  /// The low model whose name matches this high one.
  func pairedLow(for entry: InstalledModel) -> InstalledModel? {
    guard let key = Self.pairKey(entry.file, side: \.high) else { return nil }
    return videoModels.first { $0.file != entry.file && Self.pairKey($0.file, side: \.low) == key }
  }

  /// And the other way, for when the low one was chosen as the main model by mistake.
  func pairedHigh(for entry: InstalledModel) -> InstalledModel? {
    guard let key = Self.pairKey(entry.file, side: \.low) else { return nil }
    return videoModels.first { $0.file != entry.file && Self.pairKey($0.file, side: \.high) == key }
  }

  /// Wan 2.2's own boundaries: picture-to-video hands over at 10% of the noise, text-to-video
  /// at 12.5%.
  var defaultRefinerStart: Double { videoTakesImage ? 0.1 : 0.125 }

  func restoreRefiner(for entry: InstalledModel) {
    if let stored = RefinerPrefs.stored(entry.file) {
      videoRefiner = stored.file
      videoRefinerStart = stored.start
    } else if let low = pairedLow(for: entry) {
      // a matching pair is used together without asking
      videoRefiner = low.file
      videoRefinerStart = defaultRefinerStart
    } else {
      videoRefiner = ""
      videoRefinerStart = defaultRefinerStart
    }
  }

  func setVideoRefiner(_ file: String) {
    videoRefiner = file
    if !videoModel.isEmpty { RefinerPrefs.save(file, start: videoRefinerStart, for: videoModel) }
  }

  func setVideoRefinerStart(_ start: Double) {
    videoRefinerStart = start
    if !videoModel.isEmpty { RefinerPrefs.save(videoRefiner, start: start, for: videoModel) }
  }

  /// Makes the high model of a pair the main one and the low its second.
  func swapExperts() {
    guard let entry = videoEntry, let high = pairedHigh(for: entry) else { return }
    selectVideoModel(high.file)
    setVideoRefiner(entry.file)
  }

  /// How many of the steps each expert takes, from the engine's rule: the low one starts once
  /// the noise falls under (1 − start). The flow shift crowds the steps at high noise.
  var refinerSplit: (high: Int, low: Int) {
    let steps = max(1, videoSteps)
    let shift = Double(videoShift > 0 ? videoShift : 1)
    var high = 0
    for i in 0..<steps {
      let t = 1 - Double(i) / Double(steps)
      let sigma = shift * t / (1 + (shift - 1) * t)
      if sigma >= 1 - videoRefinerStart { high += 1 }
    }
    return (high, steps - high)
  }

  /// The same for the video tab: its own steps, CFG, sampler, shift, size and seed.
  private func applyToVideo(_ found: FoundSettings, takePrompt: Bool) -> [String] {
    var taken: [String] = []
    if !videoPro { videoPro = true }
    if takePrompt, let p = found.prompt, !p.isEmpty {
      prompt = p
      taken.append("промпт")
    }
    if takePrompt, let n = found.negative, !n.isEmpty {
      videoNegative = n
      videoNegativeOn = true
      taken.append("негатив")
    }
    if let steps = found.steps, steps > 0 {
      videoSteps = min(150, steps)
      taken.append("шаги \(steps)")
    }
    if let cfg = found.cfg {
      videoCFG = Float(cfg)
      taken.append(String(format: "CFG %.1f", cfg))
    }
    if let type = SettingsImport.samplerType(found.sampler, scheduler: found.scheduler, flow: true) {
      videoSampler = type
      taken.append("сэмплер \(Samplers.name(type))")
    }
    if let shift = found.shift, shift > 0 {
      videoShift = Float(shift)
      taken.append(String(format: "shift %.2f", shift))
    }
    if let seed = found.seed {
      lockedSeed = seed
      seedLocked = true
      taken.append("seed \(seed)")
    }
    if let w = found.width, let h = found.height, w > 0, h > 0 {
      setVideoCustomSize(width: w, height: h)
      taken.append("размер \(videoSize.width)×\(videoSize.height)")
    }
    return taken
  }
}
