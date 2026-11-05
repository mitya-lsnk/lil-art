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
@MainActor
final class Studio: ObservableObject {
  // what to make
  @Published var prompt = "чугунный чайник на деревянном столе, утренний свет из окна, пар"
  @Published var aspect: Aspect = .square
  @Published var megapixels: Megapixels = .one
  @Published var quality: Quality = .normal
  @Published var batch = 1
  @Published var chosenPreset: UUID?

  @Published var tab: Tab = .image {
    didSet {
      guard tab != oldValue else { return }
      swapTabModel(from: oldValue)
      refreshSpeedProfile()
      if tab == .video {
        if videoModel.isEmpty, let first = videoModels.first {
          videoModel = first.file
          videoModelChanged()
        }
        if selectedClip != nil { clipPlayer.play() }
      } else {
        // a looping clip nobody is looking at still costs decoding
        clipPlayer.pause()
      }
    }
  }

  /// Pro mode is a checkbox next to the model, not a separate panel.
  @Published var pro = false {
    didSet {
      guard pro else { return }
      let (w, h) = megapixels.size(for: aspect)
      proWidth = w
      proHeight = h
      widthText = String(w)
      heightText = String(h)
      // Start the manual controls from what the user saved for this model, or else from
      // what the model wants, never from a guess.
      if let r = savedForModel ?? recommended {
        proSteps = r.steps
        proCFG = r.cfg
        sampler = r.sampler
      }
    }
  }
  @Published var negativeOn = false
  @Published var negative = "размыто, лишние пальцы, водяной знак"
  @Published var sampler: SamplerType = .eulerATrailing
  @Published var proSteps = 4
  @Published var proCFG: Float = 3.5
  @Published var proWidth = 1024
  @Published var proHeight = 1024
  /// Raw text while the field is being edited. Snapping on every keystroke made it
  /// impossible to clear the field and type a new number.
  @Published var widthText = "1024"
  @Published var heightText = "1024"
  @Published var seedLocked = false
  @Published var lockedSeed: UInt32 = 381_204_977

  /// What the engine recommends for the model that is loaded now.
  @Published var recommended: Recommended?
  /// LoRA block in pro mode: off by default, several at once, each with its own strength.
  @Published var loraOn = false
  @Published var loraPicks: [LoRAPick] = []
  @Published var model = "flux_2_klein_4b_q8p.ckpt"
  /// The engine's upscaler, run right after the picture in the same request.
  @Published var upscaleOn = false
  @Published var upscaler = "4x_ultrasharp_f16.ckpt"
  /// 0 means the model's own factor.
  @Published var upscaleFactor = 0

  // MARK: video

  // MARK: video

  @Published var videoModel = ""
  @Published var videoSeconds: Double = 3
  @Published var videoSizeIndex = 0
  /// PRO: a size of the person's own, in the engine's 64-pixel steps, instead of the presets.
  @Published var videoCustomSize: VideoSize?
  /// The quality slider. Steps are the one number that decides both how long a clip
  /// takes and how well it holds together, so it is the one the slider moves.
  @Published var videoSteps = 6
  @Published var videoCFG: Float = 1
  @Published var videoShift: Float = 5
  @Published var videoSampler: SamplerType = .eulerATrailing
  @Published var videoNegative = "размыто, дрожание, артефакты сжатия"
  @Published var videoNegativeOn = false
  @Published var videoPro = false
  /// Wan 2.2's low-noise expert run after the chosen (high-noise) one; "" for none.
  @Published var videoRefiner = ""
  /// Where it takes over, as the share of the noise already gone (the engine's "refiner start").
  @Published var videoRefinerStart: Double = 0.1
  /// Playback speed of the finished file. Prefilled from the model, changeable in PRO.
  @Published var videoFPS = 16
  @Published var videoFormat: VideoWriter.Format = {
    let raw = UserDefaults.standard.string(forKey: "video.format") ?? ""
    return VideoWriter.Format(rawValue: raw) ?? .h264
  }() {
    didSet { UserDefaults.standard.set(videoFormat.rawValue, forKey: "video.format") }
  }
  /// The picture an image-to-video model animates. Deliberately not one of the picture
  /// tab's references: a video model takes exactly one, it is the first frame of the
  /// clip, and calling it a "reference" is how people miss it.
  @Published var videoFirstFrame: Reference?
  /// The frame the clip should arrive at. Only first-and-last-frame models (the catalog's
  /// "fl2va" ones) understand it; for the rest it is kept but not sent.
  @Published var videoLastFrame: Reference?
  /// The newest pictures from the output folder, newest first.
  @Published var recentStills: [Still] = []
  @Published var clips: [Clip] = []
  @Published var selectedClip: Clip?
  /// One player for the whole app. Building a new one on every redraw would restart the
  /// clip at every keystroke in the prompt.
  let clipPlayer = AVQueuePlayer()
  var clipLooper: AVPlayerLooper?
  /// Whether the model in use on the current tab is a distilled fast one or the full one.
  @Published var speedProfile: SpeedProfile = .full

  @Published var showMemory = false
  @Published var showGallery = false
  /// Model, settings and prompt come back as they were when the app was quit.
  @Published var restoreSession = UserDefaults.standard.object(forKey: "session.restore") as? Bool ?? true {
    didSet { UserDefaults.standard.set(restoreSession, forKey: "session.restore") }
  }

  let catalog = Catalog()
  let library: ModelLibrary
  var libraryBridge: AnyCancellable?
  var sessionSaver: AnyCancellable?

  // prompt box
  @Published var references: [Reference] = []
  @Published var strength: Float = 0.6
  @Published var showSizePad = false
  /// Sides the size field must not change while the other one is dragged.
  @Published var lockWidth = false
  @Published var lockHeight = false

  @Published var showingEnglish = false
  @Published var translating = false
  @Published var translatingNegative = false
  @Published var englishPrompt = ""

  // results
  @Published var frames: [Frame] = []
  @Published var selected: Frame?
  /// Everything the current run produced, so a batch of four arrives as four, not as one
  /// picture that quietly replaced the last.
  @Published var batchGroup: [Frame] = []
  /// The picture as it is still forming, handed over by the engine on each step.
  @Published var livePreview: NSImage?
  @Published var gridMode = false
  @Published var fullscreen: Frame?
  @Published var hudMode: HUDMode = .auto
  @Published var hudShown = true
  /// The in-between steps of a picture look like noise; most people would rather not watch.
  @Published var showProgressPreview = UserDefaults.standard.bool(forKey: "stage.preview") {
    didSet { UserDefaults.standard.set(showProgressPreview, forKey: "stage.preview") }
  }
  @Published var stepFraction = 0.0
  @Published var notices: [Notice] = []
  @Published var settingsPage: SettingsPage = .general
  /// Kept by the settings window itself, so the gear can close what it opened.
  /// Whether the pointer is over the picture, where the arrow keys leaf through results.
  var stageHovered = false
  var keyMonitor: Any?

  // run state
  @Published var busy = false
  @Published var stepText = ""
  @Published var status = "готов"
  @Published var queued = 0
  @Published var footprint = 0.0
  @Published var systemFree = 0.0
  @Published var cacheGB = 0.0

  let presets = [
    Preset(name: "плёнка 35 мм", suffix: ", снято на плёнку 35 мм, мягкое зерно, тёплый свет"),
    Preset(
      name: "продукт на белом", suffix: ", предметная съёмка на белом фоне, ровный студийный свет"),
    Preset(
      name: "мягкий портрет", suffix: ", портрет, мягкий рассеянный свет, малая глубина резкости"),
  ]

  let translator = Translator()
  let monitor = SystemMonitor()
  let power = PowerMode()
  let engineHost = EngineHost()
  let assist = PromptAssist()
  let engine = Engine()
  var work: Task<Void, Never>?
  var hudTask: Task<Void, Never>?
  var memTimer: Timer?
  var bridge: AnyCancellable?
  var catalogBridge: AnyCancellable?
  var engineBridge: AnyCancellable?
  var assistBridge: AnyCancellable?

  var outDir: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("lil-art/out")
  }

  init() {
    let models = ModelsFolder.url
    // a folder on a disk that is not plugged in is never made: it would be a fake one on the Mac
    if ModelsFolder.isReachable(models) {
      try? FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
    }
    library = ModelLibrary(modelsDir: models)
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    MediaGenerationEnvironment.default.externalUrls = [models]
    // The cache choice is the difference between a model staying in memory and being
    // reloaded every time, so it has no business resetting on every launch.
    if UserDefaults.standard.object(forKey: "engine.cacheGB") != nil {
      setCache(UserDefaults.standard.double(forKey: "engine.cacheGB"))
    } else {
      cacheGB = Double(MediaGenerationEnvironment.default.maxTotalWeightsCacheSize) / 1_073_741_824
    }
    bridge = translator.objectWillChange.sink { [weak self] _ in
      Task { @MainActor in self?.objectWillChange.send() }
    }
    catalogBridge = catalog.objectWillChange.sink { [weak self] _ in
      Task { @MainActor in self?.objectWillChange.send() }
    }
    libraryBridge = library.objectWillChange.sink { [weak self] _ in
      Task { @MainActor in self?.objectWillChange.send() }
    }
    engineBridge = engineHost.objectWillChange.sink { [weak self] _ in
      Task { @MainActor in self?.objectWillChange.send() }
    }
    assistBridge = assist.objectWillChange.sink { [weak self] _ in
      Task { @MainActor in self?.objectWillChange.send() }
    }
    library.catalog = catalog
    library.engineHooks = { [weak self] in
      self?.engineHooks() ?? EngineHooks(pause: {}, resume: { _, _ in }, waitIdle: {})
    }
    library.engineTag = { [weak self] in self?.engineHost.installedTag ?? "" }
    library.fallbackFamily = { [weak self] in self?.currentFamily }
    library.onListChanged = { [weak self] in self?.syncWithLibrary() }
    library.onReady = { [weak self] item in self?.adopt(item) }
    library.onFailure = { [weak self] job, reason in
      self?.notify(
        Notice(
          title: job.role == .upscaler ? "Upscaler не скачался" : "Не получилось добавить «\(job.name)»",
          message: Self.capitalized(reason),
          actions: [.init("Модели…", .openModels)]))
    }
    translator.onProblem = { [weak self] problem in self?.report(problem) }
    installKeyMonitor()
    Task { await CatalogCache.refreshIfStale() }
    Task { await ControlNets.refreshCatalog() }
    if restoreSession { restore() }
    syncWithLibrary()
    savedForModel = ModelPrefs.load(model)
    refreshMemory()
    NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.saveSession() }
    }
    // saved along the way too, so a crash does not lose the prompt
    sessionSaver = objectWillChange
      .throttle(for: .seconds(5), scheduler: RunLoop.main, latest: true)
      .sink { [weak self] _ in self?.saveSession() }
    memTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.refreshMemory() }
    }
  }

  // MARK: settings in effect

  // MARK: translation

  // MARK: translation

  /// The prompt text the English version was made from. The English is only ever used
  /// while it still matches what is in the box: generating a cat from a prompt that was
  /// since edited to say "собака" is exactly what this guards against.
  var englishSource = ""
  var translationRun = 0

  /// Translates what is in the box now, on request; `improve` also has the text embellished.
  /// Nothing is ever translated behind the person's back: a run sends this English only while
  /// the Russian it came from is still what is in the box (`modelText`).
  func translate(improve: Bool = false) {
    // the zones' descriptions go with the same button
    translateRegions()
    switch TranslationTarget.choose(
      improve: improve, showingEnglish: showingEnglish, english: englishPrompt,
      englishIsCurrent: englishCurrent, prompt: prompt)
    {
    case .nothingToTranslate:
      status = "английский уже готов: правьте его прямо в поле"
    case .improveEnglish(let text):
      improveEnglishSide(text)
    case .translate(let text):
      translateRussian(text, improve: improve)
    }
  }

  private func translateRussian(_ text: String, improve: Bool) {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    translationRun += 1
    let run = translationRun
    translating = true
    Task {
      let out = await english(for: text, improve: improve)
      // a newer request since then makes this one history
      guard run == translationRun else { return }
      translating = false
      // and an edit since then makes the result belong to text that is gone
      guard text == prompt else { return }
      store(english: out, from: text)
      // asked for, so shown: the English side is editable for a clumsy word
      showingEnglish = !englishPrompt.isEmpty
    }
  }

  /// «Улучшить» on the English side: the English on screen, corrections included, gets the detail.
  private func improveEnglishSide(_ text: String) {
    let source = prompt
    translationRun += 1
    let run = translationRun
    translating = true
    Task {
      let out = await english(for: text, improve: true)
      guard run == translationRun else { return }
      translating = false
      // the Russian it belongs to must still be in the box, and the English not corrected meanwhile
      guard source == prompt, englishPrompt == text else { return }
      englishPrompt = out
    }
  }

  // MARK: generation

  var queue: [Job] = []
  /// Which kind of work is running, so each tab shows only its own progress.
  @Published var running: Tab?
  /// Bumped by every new worker and every cancel. A cancelled run can take a moment to
  /// unwind; once it no longer holds the current number it may not touch the window.
  var runID = 0

  var engineKey: String { engineHost.host + String(engineHost.port) }

  static let stampFormat: DateFormatter = {
    let format = DateFormatter()
    format.locale = Locale(identifier: "en_US_POSIX")
    format.dateFormat = "yyyyMMdd-HHmmss-SSS"
    return format
  }()

  // MARK: notices

  // MARK: leafing through results

  // MARK: overlay

  // MARK: memory and folders

  // MARK: upscaler

  // MARK: video settings

  // MARK: swapped parts

  // MARK: editing

  // MARK: editing

  /// The picture the edit tab changes.
  @Published var editSource: Reference?
  /// Layout boxes of the picture tab and of the edit tab (`Regions.swift`).
  @Published var regions: [Region] = []
  @Published var editRegions: [Region] = []
  /// The edit picture takes boxes instead of mask strokes.
  @Published var regionDrawing = false
  /// More pictures the edit can borrow from: a face, a costume, a style.
  @Published var editRefs: [Reference] = []
  static let maxEditRefs = 3
  /// How much of the picture a model that does not edit by instruction may change (img2img).
  @Published var editStrength: Double = 0.7
  /// The painted mask at the source's size: white where the picture is redrawn. nil or empty
  /// means the whole picture.
  @Published var editMask: CGImage? {
    didSet { maskPainted = editMask.map(Self.hasPaint) ?? false }
  }
  /// Whether the mask has any paint; worked out once per change, not on every redraw.
  @Published var maskPainted = false
  /// The edit tab's latest result, apart from whatever the picture tab shows.
  @Published var editResult: Frame?
  /// Brush radius as a share of the picture's shorter side.
  @Published var maskBrush: Double = 0.05
  @Published var maskErasing = false
  /// Redraw the masked part from scratch instead of from what is there.
  @Published var maskFresh = false
  /// The stage shows the latest result instead of the source.
  @Published var editShowResult = false
  @Published var controlNetOn = false
  @Published var controlPicks: [ControlPick] = []
  /// ControlNet and helper files on their way down: file → fraction.
  @Published var controlDownloads: [String: Double] = [:]
  /// Phrases the person saved for edits, one click away.
  @Published var editPhrases: [String] =
    UserDefaults.standard.stringArray(forKey: "edit.phrases") ?? []
  {
    didSet { UserDefaults.standard.set(editPhrases, forKey: "edit.phrases") }
  }
  /// Each tab keeps the model last used on it; the picture tab's is in `model` while it shows.
  var imageTabModel = ""
  var editTabModel = UserDefaults.standard.string(forKey: "edit.model") ?? "" {
    didSet { UserDefaults.standard.set(editTabModel, forKey: "edit.model") }
  }
  /// The model's own values for its finer settings, per model, from the engine.
  @Published var tweakDefaults: [String: [String: Double]] = [:]
  /// The "найти настройки" sheet: from a picture or from Civitai.
  @Published var showSettingsFinder = false
  /// Moving the whole models folder: how far it is, nil when nothing moves.
  @Published var folderMove: Double?
  @Published var folderMoveNote = ""

  var modelEntry: InstalledModel? { models.first(where: { $0.file == model }) }
  /// Whether the picture model in use changes pictures by description.
  var canEdit: Bool { modelEntry?.canEdit ?? false }
  var editModels: [InstalledModel] { models.filter(\.canEdit) }

  func pickEditSource() {
    if let url = pickImage("выберите картинку, которую править") { setEditSource(url) }
  }

  // MARK: recent pictures

  // MARK: settings saved per model

  // MARK: settings saved per model

  /// What the user saved for the current model. It replaces the model's own recommendation
  /// in both modes: simple mode sends it too.
  @Published var savedForModel: Recommended?

  func saveForModel() {
    let settings = Recommended(steps: proSteps, cfg: proCFG, sampler: sampler)
    ModelPrefs.save(settings, for: model)
    savedForModel = settings
    status = "настройки запомнены для этой модели"
  }

  // MARK: the session, kept across launches

  var lastSavedSession: Data?

  func restore() {
    guard let data = UserDefaults.standard.data(forKey: "session.last"),
      let session = try? JSONDecoder().decode(Session.self, from: data)
    else { return }
    prompt = session.prompt
    negative = session.negative
    negativeOn = session.negativeOn
    model = session.model
    aspect = Aspect(rawValue: session.aspect) ?? aspect
    megapixels = Megapixels(rawValue: session.megapixels) ?? megapixels
    quality = Quality(rawValue: session.quality) ?? quality
    batch = session.batch
    chosenPreset = presets.first(where: { $0.name == session.preset })?.id
    // switching pro on seeds the manual fields; the saved values then take their place
    pro = session.pro
    if let saved = SamplerType(rawValue: Int8(clamping: session.sampler)) { sampler = saved }
    proSteps = session.steps
    proCFG = session.cfg
    proWidth = session.width
    proHeight = session.height
    widthText = String(session.width)
    heightText = String(session.height)
    showSizePad = session.showSizePad
    seedLocked = session.seedLocked
    lockedSeed = session.seed
    loraOn = session.loraOn
    loraPicks = zip(session.loras, session.loraWeights).map { LoRAPick(file: $0, weight: $1) }
    strength = session.strength
    upscaleOn = session.upscaleOn ?? false
    upscaler = session.upscaler ?? upscaler
    upscaleFactor = session.upscaleFactor ?? 0
    videoModel = session.videoModel ?? ""
    videoSeconds = session.videoSeconds ?? videoSeconds
    videoSizeIndex = session.videoSizeIndex ?? 0
    videoSteps = session.videoSteps ?? videoSteps
    videoCFG = session.videoCFG ?? videoCFG
    videoShift = session.videoShift ?? videoShift
    videoFPS = session.videoFPS ?? videoFPS
    if let raw = session.videoSampler, let saved = SamplerType(rawValue: Int8(clamping: raw)) {
      videoSampler = saved
    }
    videoPro = session.videoPro ?? false
    videoNegativeOn = session.videoNegativeOn ?? false
    videoNegative = session.videoNegative ?? videoNegative
    if session.videoTab == true, !videoModel.isEmpty { tab = .video }
    refreshSpeedProfile()
  }

}
/// A small picture for a row in the sidebar. The full image is read only by the engine;
/// keeping a 6000-pixel photo in memory to draw it 42 points wide was pure waste.
enum Thumbnail {
  static func make(_ url: URL, maxPixel: Int = 512) -> NSImage? {
    guard let image = cgImage(url, maxPixel: maxPixel) else { return nil }
    return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
  }

  static func cgImage(_ url: URL, maxPixel: Int) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateThumbnailAtIndex(
      source, 0,
      [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixel,
      ] as CFDictionary)
  }
}
enum Mem {
  static func footprintGB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    guard kr == KERN_SUCCESS else { return 0 }
    return Double(info.phys_footprint) / 1_073_741_824
  }

  // Each mach_host_self() call adds a reference to the port; looked up once instead.
  private static let host = mach_host_self()
  private static let pageSize: vm_size_t = {
    var size: vm_size_t = 0
    host_page_size(host, &size)
    return size
  }()

  static func systemAvailableGB() -> Double {
    var stats = vm_statistics64_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &stats) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics64(host, HOST_VM_INFO64, $0, &count)
      }
    }
    guard kr == KERN_SUCCESS else { return 0 }
    let pages =
      UInt64(stats.free_count) + UInt64(stats.inactive_count) + UInt64(stats.purgeable_count)
    return Double(pages * UInt64(pageSize)) / 1_073_741_824
  }

  static var machineGB: Double {
    Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
  }
}
