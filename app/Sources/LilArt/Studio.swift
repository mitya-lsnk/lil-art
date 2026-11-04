import AVFoundation
import AppKit
import Combine
import CoreGraphics
import Darwin
import Foundation
import MediaGenerationKit
import SwiftUI
import UniformTypeIdentifiers

enum Aspect: String, Hashable, CaseIterable {
  case square, landscape, portrait, wide, tall

  var label: String {
    switch self {
    case .square: return "1:1"
    case .landscape: return "3:2"
    case .portrait: return "2:3"
    case .wide: return "16:9"
    case .tall: return "9:16"
    }
  }
  /// width / height
  var ratio: Double {
    switch self {
    case .square: return 1
    case .landscape: return 3.0 / 2.0
    case .portrait: return 2.0 / 3.0
    case .wide: return 16.0 / 9.0
    case .tall: return 9.0 / 16.0
    }
  }
  /// The same ratio stood on its end.
  var flipped: Aspect {
    switch self {
    case .square: return .square
    case .landscape: return .portrait
    case .portrait: return .landscape
    case .wide: return .tall
    case .tall: return .wide
    }
  }
  /// Only one of each pair belongs in the menu; the flip button reaches the other.
  static var menu: [Aspect] { [.square, .landscape, .wide] }
}

/// Size is chosen by area, not by typing pixel counts.
enum Megapixels: Double, Hashable, CaseIterable {
  case half = 0.5, one = 1, two = 2, four = 4

  var label: String {
    switch self {
    case .half: return "0.5 мп"
    case .one: return "1 мп"
    case .two: return "2 мп"
    case .four: return "4 мп"
    }
  }

  /// Pixel size for an aspect, snapped to a multiple of 64 as the models expect.
  func size(for aspect: Aspect) -> (Int, Int) {
    let area = rawValue * 1_000_000
    let h = (area / aspect.ratio).squareRoot()
    let w = h * aspect.ratio
    func snap(_ v: Double) -> Int { max(256, Int((v / 64).rounded()) * 64) }
    return (snap(w), snap(h))
  }
}

enum Quality: String, Hashable, CaseIterable {
  case fast, normal, max

  var label: String {
    switch self {
    case .fast: return "быстро"
    case .normal: return "норма"
    case .max: return "максимум"
    }
  }

  /// Quality never invents a step count; it scales the one the model (or the user, for
  /// this model) settled on, so a 4-step turbo model is never asked for 30.
  func steps(from base: Int) -> Int {
    switch self {
    case .fast: return Swift.max(1, Int((Double(base) * 0.5).rounded()))
    case .normal: return base
    case .max: return Swift.min(60, Int((Double(base) * 2).rounded()))
    }
  }
}

enum HUDMode: String, Hashable, CaseIterable {
  case auto, always, never

  var label: String {
    switch self {
    case .auto: return "авто"
    case .always: return "всегда"
    case .never: return "нет"
    }
  }
}

enum Tab: Hashable, CaseIterable {
  case image, edit, video
  var label: String {
    switch self {
    case .image: return "изображение"
    case .edit: return "правка"
    case .video: return "видео"
    }
  }
}

struct Preset: Identifiable, Hashable {
  let id = UUID()
  let name: String
  let suffix: String
}

/// One LoRA chosen for the next run, with its own strength.
struct LoRAPick: Identifiable, Hashable {
  let id = UUID()
  var file: String
  var weight: Double = 0.6
}

/// A picture handed to the model alongside the prompt.
enum RefRole: String, CaseIterable, Hashable {
  case source, mask, moodboard

  var label: String {
    switch self {
    case .source: return "исходник"
    case .mask: return "маска"
    case .moodboard: return "референс"
    }
  }
  var hint: String {
    switch self {
    case .source: return "модель перерисовывает это изображение, Denoise ниже"
    case .mask: return "белое перерисовывается, чёрное остаётся"
    case .moodboard: return "берётся только настроение и стиль, не композиция"
    }
  }
}

struct Reference: Identifiable, Hashable {
  let id = UUID()
  let url: URL
  var role: RefRole
  let thumb: NSImage
}

struct Frame: Identifiable {
  let id = UUID()
  let image: NSImage
  let url: URL
  /// Display name of the model that made it.
  let model: String
  let prompt: String
  let seed: UInt32
  let steps: Int
  let width: Int
  let height: Int
  let seconds: Double
  /// Has see-through pixels; the stage puts a checkerboard behind it.
  var hasAlpha = false
}

/// Where a picture goes on the video tab.
enum FrameSlot: Hashable {
  case first, last

  var label: String {
    switch self {
    case .first: return "первый кадр"
    case .last: return "последний кадр"
    }
  }
}

/// A picture made earlier, offered on the video tab so it can become a frame in one click.
struct Still: Identifiable {
  let url: URL
  let thumb: NSImage
  var id: URL { url }
}

/// A finished clip: the file on disk, plus its first frame to stand for it in the list.
struct Clip: Identifiable {
  let id = UUID()
  let url: URL
  let poster: NSImage
  let prompt: String
  let seed: UInt32
  let frames: Int
  let fps: Int
  let width: Int
  let height: Int
  let steps: Int
  /// How long it took to make, not how long it plays.
  let took: Double
  /// Read back from the output folder on launch, so the settings behind it are unknown.
  var restored = false

  var duration: Double { Double(frames) / Double(max(1, fps)) }
  var sizeLabel: String { "\(width) × \(height)" }
  var lengthLabel: String { String(format: "%.1f с · %d кадров", duration, frames) }
}

/// CGImage is not Sendable, and the progress callback crosses threads.
final class PreviewBox: @unchecked Sendable {
  let image: CGImage
  init(_ image: CGImage) { self.image = image }
}

/// What the engine itself considers right for the loaded model. It fills these in from
/// the catalog when the model is opened, and overriding them blindly is how a turbo model
/// ends up producing mush.
struct Recommended: Sendable, Equatable {
  var steps: Int
  var cfg: Float
  var sampler: SamplerType
  /// The model's own value for every finer setting (`Tweaks`), as the engine recommends it.
  var defaults: [String: Double] = [:]
}

enum SettingsPage: Hashable, CaseIterable {
  case general, prompt, translation, engine, look, about

  var title: String {
    switch self {
    case .general: return "Общие"
    case .prompt: return "Prompt"
    case .translation: return "Перевод"
    case .engine: return "Движок"
    case .look: return LilSettingsTab.look(self).1
    case .about: return LilSettingsTab.about(self).1
    }
  }
  var symbol: String {
    switch self {
    case .general: return "gearshape"
    case .prompt: return "text.cursor"
    case .translation: return "character.bubble"
    case .engine: return "cpu"
    case .look: return LilSettingsTab.look(self).2
    case .about: return LilSettingsTab.about(self).2
    }
  }
}

/// A problem shown as a card in the corner: what happened, and buttons that deal with it.
@available(macOS 26, *)
struct Notice: Identifiable {
  enum Action {
    case openSettings(SettingsPage)
    case openModels
    case useTranslator(Translator.Engine)
    case restartEngine
    case retryTranslation
    case freeMemory
  }

  struct Choice {
    let title: String
    let action: Action
    init(_ title: String, _ action: Action) {
      self.title = title
      self.action = action
    }
  }

  let id = UUID()
  let title: String
  let message: String
  var actions: [Choice] = []
}

/// Sampler, steps and cfg the user settled on for a model, kept by its file name.
enum ModelPrefs {
  private static let key = "model.saved"

  static func load(_ model: String) -> Recommended? {
    guard let all = UserDefaults.standard.dictionary(forKey: key),
      let item = all[model] as? [String: Any],
      let steps = (item["steps"] as? NSNumber)?.intValue,
      let cfg = (item["cfg"] as? NSNumber)?.floatValue,
      let raw = (item["sampler"] as? NSNumber)?.int8Value,
      let sampler = SamplerType(rawValue: raw)
    else { return nil }
    return Recommended(steps: steps, cfg: cfg, sampler: sampler)
  }

  static func save(_ settings: Recommended?, for model: String) {
    var all = UserDefaults.standard.dictionary(forKey: key) ?? [:]
    if let settings {
      all[model] = [
        "steps": settings.steps, "cfg": Double(settings.cfg), "sampler": Int(settings.sampler.rawValue),
      ]
    } else {
      all[model] = nil
    }
    UserDefaults.standard.set(all, forKey: key)
  }
}

/// One picture, exactly as it will be asked of the engine.
struct ImageRequest {
  var model: String
  var prompt: String
  var negative: String
  var width: Int
  var height: Int
  /// nil means "whatever the model asked for".
  var steps: Int?
  var seed: UInt32
  var cfg: Float?
  var sampler: SamplerType?
  var loras: [LoRA]?
  var strength: Float
  var inputs: [MediaGenerationPipeline.Input]
  var upscaler: String?
  var upscaleFactor: Int
  /// Parts added in the models window, read instead of the standard ones, slot by slot.
  var parts: [ModelParts.Slot: String] = [:]
  /// Finer settings changed by hand for this model (`Tweaks`).
  var tweaks: [String: Double] = [:]
  /// ControlNets for an edit; nil keeps the model's own.
  var controls: [Control]? = nil
  /// Layout boxes (FLUX.3 klein), written into the prompt when its turn comes.
  var regions: [Region] = []
  var regionsEdit = false
}

/// One clip, exactly as it will be asked of the engine.
struct VideoRequest {
  var model: String
  var prompt: String
  var negative: String
  var width: Int
  var height: Int
  var frames: Int
  var steps: Int
  var seed: UInt32
  var cfg: Float
  var sampler: SamplerType?
  var shift: Float
  var inputs: [MediaGenerationPipeline.Input]
  /// Parts added in the models window, read instead of the standard ones, slot by slot.
  var parts: [ModelParts.Slot: String] = [:]
  /// Finer settings changed by hand for this model (`Tweaks`).
  var tweaks: [String: Double] = [:]
  /// Wan 2.2's second expert: the low-noise model that takes over once the noise is below
  /// `refinerStart` of the way (the engine unloads the first before loading this one).
  var refiner: String? = nil
  var refinerStart: Float = 0.1
  /// Set when the person overrode whether the model takes a picture.
  var takesImage: Bool? = nil
}

/// Holds the pipeline off the main thread so the window never blocks.
actor Engine {
  private var pipeline: MediaGenerationPipeline?
  /// The configuration exactly as the engine recommended it for this model. Each run starts
  /// from a fresh copy, so one run's manual settings never leak into the next one. Before
  /// this, a pro-mode step count quietly stayed in effect after switching back to simple.
  private var base: MediaGenerationPipeline.Configuration?
  private var loadedModel: String?
  private var loadedBackendKey = ""

  /// The pipeline and its recommendation for exactly this model, handed back as copies.
  /// The actor lets other calls in at every await, so a different model opened while a
  /// run is in flight must not be able to change what that run is using.
  private func load(_ model: String, backend: MediaGenerationPipeline.Backend, key: String)
    async throws -> (MediaGenerationPipeline, MediaGenerationPipeline.Configuration)
  {
    if let pipeline, let base, loadedModel == model, loadedBackendKey == key {
      return (pipeline, base)
    }
    var fresh = try await MediaGenerationPipeline.fromPretrained(model, backend: backend)
    // The engine's recommendation leaves some models at shift 1 although their maker writes
    // another into the description (FLUX.3 klein: 16); at 1 the pictures come out with
    // artefacts. The maker's word is the model's own value from here on.
    if let note = CatalogCache.entries()[model]?.note, let shift = NoteSettings(note).shift,
      shift > 0
    {
      fresh.configuration.shift = Float(shift)
    }
    pipeline = fresh
    base = fresh.configuration
    loadedModel = model
    loadedBackendKey = key
    return (fresh, fresh.configuration)
  }

  @discardableResult
  func prepare(model: String, backend: MediaGenerationPipeline.Backend, key: String) async throws
    -> Recommended
  {
    let base = try await load(model, backend: backend, key: key).1
    return Recommended(
      steps: base.steps, cfg: base.guidanceScale, sampler: base.sampler,
      defaults: Tweaks.defaults(from: base))
  }

  /// Makes one picture and writes it straight to `destination` as PNG. Returns whether the
  /// picture has transparent pixels.
  @discardableResult
  func run(
    _ r: ImageRequest, backend: MediaGenerationPipeline.Backend, key: String, to destination: URL,
    onStep: @escaping @Sendable (Int, Int) -> Void,
    onPreview: (@Sendable (PreviewBox) -> Void)?
  ) async throws -> Bool {
    let loaded = try await load(r.model, backend: backend, key: key)
    var p = loaded.0
    let base = loaded.1
    p.configuration = base
    // nil means "whatever the model asked for" — only touch what the user actually set.
    p.configuration.width = r.width
    p.configuration.height = r.height
    p.configuration.seed = r.seed
    p.configuration.batchCount = 1
    p.configuration.batchSize = 1
    if let steps = r.steps { p.configuration.steps = steps }
    if let cfg = r.cfg { p.configuration.guidanceScale = cfg }
    if let sampler = r.sampler { p.configuration.sampler = sampler }
    p.configuration.loras = Self.merge(r.loras, into: base)
    p.configuration.strength = r.inputs.isEmpty ? 1 : r.strength
    p.configuration.upscaler = r.upscaler
    p.configuration.upscalerScaleFactor = r.upscaler == nil ? 0 : r.upscaleFactor
    Tweaks.apply(r.tweaks, to: &p.configuration)
    if let controls = r.controls { p.configuration.controls = controls }
    let results = try await PartsOverride.using(r.parts, for: r.model) {
      try await Self.generate(
        p, prompt: r.prompt, negative: r.negative, inputs: r.inputs, onStep: onStep,
        onPreview: onPreview)
    }
    guard let first = results.first, let encoded = TensorImage.png(first.tensor) else {
      throw Err.empty
    }
    try encoded.png.write(to: destination)
    return encoded.hasAlpha
  }

  /// Video is the same request with more frames asked for. What comes back is one
  /// picture per frame, in order — the engine never makes a video file itself.
  func runVideo(
    _ r: VideoRequest, backend: MediaGenerationPipeline.Backend, key: String,
    onStep: @escaping @Sendable (Int, Int) -> Void,
    onPreview: (@Sendable (PreviewBox) -> Void)?
  ) async throws -> [Data] {
    let loaded = try await load(r.model, backend: backend, key: key)
    var p = loaded.0
    p.configuration = loaded.1
    p.configuration.width = r.width
    p.configuration.height = r.height
    p.configuration.seed = r.seed
    p.configuration.steps = r.steps
    p.configuration.guidanceScale = r.cfg
    p.configuration.numFrames = r.frames
    p.configuration.batchCount = 1
    p.configuration.batchSize = 1
    if let sampler = r.sampler { p.configuration.sampler = sampler }
    if r.shift > 0 { p.configuration.shift = r.shift }
    // For image-to-video the picture is a condition, not a half-finished canvas, so it is
    // never partially denoised the way img2img is.
    p.configuration.strength = 1
    p.configuration.upscaler = nil
    p.configuration.upscalerScaleFactor = 0
    Tweaks.apply(r.tweaks, to: &p.configuration)
    p.configuration.refinerModel = r.refiner
    if let refiner = r.refiner {
      p.configuration.refinerStart = r.refinerStart
      // the kit tells the engine about both models; the second one must be known here too
      PartsOverride.prime(refiner)
      if !PartsOverride.isKnown(refiner) {
        _ = try? await MediaGenerationPipeline.fromPretrained(refiner, backend: backend)
      }
    }
    let results = try await PartsOverride.using(r.parts, takesImage: r.takesImage, for: r.model) {
      try await Self.generate(
        p, prompt: r.prompt, negative: r.negative, inputs: r.inputs, onStep: onStep,
        onPreview: onPreview)
    }
    guard !results.isEmpty else { throw Err.empty }
    var pngs: [Data] = []
    pngs.reserveCapacity(results.count)
    for result in results {
      try Task.checkCancellation()
      guard let encoded = TensorImage.png(result.tensor) else { throw Err.empty }
      pngs.append(encoded.png)
    }
    return pngs
  }

  /// Some models ship with their own LoRA baked into the recommendation (lightning and
  /// similar); the user's picks are added on top of those, never instead of them.
  private static func merge(_ picks: [LoRA]?, into base: MediaGenerationPipeline.Configuration)
    -> [LoRA]
  {
    guard let picks else { return base.loras }
    let picked = Set(picks.compactMap(\.file))
    return base.loras.filter { !picked.contains($0.file ?? "") } + picks
  }

  private static func generate(
    _ p: MediaGenerationPipeline, prompt: String, negative: String,
    inputs: [MediaGenerationPipeline.Input],
    onStep: @escaping @Sendable (Int, Int) -> Void,
    onPreview: (@Sendable (PreviewBox) -> Void)?
  ) async throws -> [MediaGenerationPipeline.Result] {
    try await p.generate(prompt: prompt, negativePrompt: negative, inputs: inputs) {
      state, preview in
      if case let .generating(step, total) = state { onStep(step, total) }
      // Reading preview[0] is what decodes the picture, and decoding is where the engine
      // code once took the whole app down; it only happens when someone is watching.
      if let onPreview, let preview, preview.count > 0 { onPreview(PreviewBox(preview[0])) }
    }
  }

  func release() {
    pipeline = nil
    base = nil
    loadedModel = nil
    loadedBackendKey = ""
  }

  enum Err: Error { case notReady, empty }
}

/// Lets exactly one of two racing outcomes through.
private final class OnceFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var taken = false

  func claim() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if taken { return false }
    taken = true
    return true
  }
}

/// Runs an async job with a ceiling on how long it may take. Nothing in the app is
/// allowed to block generation forever — that is what stalled the queue before.
///
/// The deadline is real: the answer comes back when time is up even if the work ignores
/// cancellation. A task group would not do that, because it waits for every child.
func withDeadline<T: Sendable>(
  _ seconds: Double, fallback: T, _ work: @escaping @Sendable () async -> T
) async -> T {
  let once = OnceFlag()
  return await withCheckedContinuation { (done: CheckedContinuation<T, Never>) in
    let worker = Task {
      let value = await work()
      if once.claim() { done.resume(returning: value) }
    }
    Task {
      try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
      if once.claim() {
        worker.cancel()
        done.resume(returning: fallback)
      }
    }
  }
}

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
  private var clipLooper: AVPlayerLooper?
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
  private var libraryBridge: AnyCancellable?
  private var sessionSaver: AnyCancellable?

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
  private var keyMonitor: Any?

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
  let engineHost = EngineHost()
  let assist = PromptAssist()
  private let engine = Engine()
  private var work: Task<Void, Never>?
  private var hudTask: Task<Void, Never>?
  private var memTimer: Timer?
  private var bridge: AnyCancellable?
  private var catalogBridge: AnyCancellable?
  private var engineBridge: AnyCancellable?
  private var assistBridge: AnyCancellable?

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

  /// The engine builds its GPU programs and maps the weights on first use, which costs
  /// about half a minute once per launch. Doing it in the background right away means the
  /// first frame the user asks for is already a warm one.
  func warmUp() {
    engineHost.autoStart(modelsDir: modelsDir)
    Task { await loadClips() }
    Task { await loadStills() }
    Task { [weak self] in
      guard let self else { return }
      // The engine is a separate program; there is nothing to warm until it answers.
      for _ in 0..<30 {
        if self.engineHost.ready { break }
        try? await Task.sleep(nanoseconds: 700_000_000)
      }
      guard self.engineHost.ready else {
        self.status = "движок не запущен"
        return
      }
      self.status = "прогреваю движок"
      let warm = self.tab == .video && !self.videoModel.isEmpty ? self.videoModel : self.model
      do {
        let r = try await self.engine.prepare(
          model: warm, backend: self.engineHost.backend, key: self.engineKey)
        if warm == self.model { self.recommended = r }
        self.tweakDefaults[warm] = r.defaults
        if !self.busy { self.status = "готов" }
        self.refreshMemory()
      } catch {
        self.status = "движок не открылся: \(error.localizedDescription)"
        self.notify(
          Notice(
            title: "Движок не открыл модель",
            message: Self.capitalized(error.localizedDescription),
            actions: [.init("Перезапустить движок", .restartEngine), .init("Модели…", .openModels)]))
      }
    }
  }

  // MARK: settings in effect

  var effectiveSize: (Int, Int) {
    pro ? (proWidth, proHeight) : megapixels.size(for: aspect)
  }
  /// In the simple view the model decides; quality only scales its own recommendation,
  /// so a 4-step turbo model never gets asked for 30 steps at cfg 3.5.
  var effectiveSteps: Int? {
    if pro { return proSteps }
    guard let base = savedForModel?.steps ?? recommended?.steps else { return nil }
    return quality.steps(from: base)
  }
  var effectiveCFG: Float? { pro ? proCFG : savedForModel?.cfg }
  var effectiveSampler: SamplerType? { pro ? sampler : savedForModel?.sampler }

  var effectiveNegative: String { pro && negativeOn ? negative : "" }

  /// What the next run is likely to want, and whether it fits.
  var memoryEstimateGB: Double {
    let (w, h) = effectiveSize
    return Budget.memoryGB(width: w, height: h)
  }
  var memoryVerdict: Budget.Verdict {
    Budget.verdict(needGB: memoryEstimateGB, freeGB: systemFree + footprint)
  }
  var timeEstimate: String {
    let (w, h) = effectiveSize
    let one = Budget.seconds(width: w, height: h, steps: effectiveSteps ?? recommended?.steps ?? 4)
    return Budget.humanTime(one * Double(max(1, batch)))
  }

  var sizeLabel: String {
    let (w, h) = effectiveSize
    return "\(w) × \(h)"
  }

  /// Turns whatever is in the size fields into something the engine will accept.
  /// Called when a field is committed and again just before generating, so a half-typed
  /// number can never reach the engine.
  func commitSize() {
    let w = snapTo64(Int(widthText.filter(\.isNumber)) ?? proWidth)
    let h = snapTo64(Int(heightText.filter(\.isNumber)) ?? proHeight)
    proWidth = w
    proHeight = h
    widthText = String(w)
    heightText = String(h)
  }

  // MARK: translation

  /// The prompt text the English version was made from. The English is only ever used
  /// while it still matches what is in the box: generating a cat from a prompt that was
  /// since edited to say "собака" is exactly what this guards against.
  private var englishSource = ""
  private var translationRun = 0

  /// Translates what is in the box now, on request; `improve` also has the text embellished.
  /// Nothing is ever translated behind the person's back: a run sends this English only while
  /// the Russian it came from is still what is in the box (`modelText`).
  func translate(improve: Bool = false) {
    let text = prompt
    // the zones' descriptions go with the same button
    translateRegions()
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

  /// The English in the box was made from exactly the text there now, so a run sends it.
  var englishCurrent: Bool { !englishPrompt.isEmpty && englishSource == prompt }
  /// There is an English, but the Russian has changed since: a run sends the Russian.
  var englishStale: Bool { !englishPrompt.isEmpty && englishSource != prompt }

  /// The box stays on whichever side the person is looking at. Flipping it to the English
  /// on every translation (each run makes one) took the Russian away mid-typing.
  private func store(english out: String, from text: String) {
    englishPrompt = out == text ? "" : out
    englishSource = text
  }

  /// A hand-corrected English is what the model reads, for as long as the Russian it was made
  /// from stays as it is.
  func editEnglish(_ text: String) {
    englishPrompt = text
  }

  /// Every zone of the tab in front whose description has no English yet for its text.
  private func translateRegions() {
    let edit = tab == .edit
    let wanted = (edit ? editRegions : regions).filter {
      !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.englishSource != $0.text
    }
    for region in wanted {
      let text = region.text
      Task {
        let out = await english(for: text)
        var list = edit ? editRegions : regions
        // a box removed or retyped meanwhile keeps what it has now
        guard let i = list.firstIndex(where: { $0.id == region.id }), list[i].text == text else { return }
        list[i].english = out == text ? "" : out
        list[i].englishSource = text
        if edit { editRegions = list } else { regions = list }
      }
    }
  }

  /// One translation with a ceiling on how long it may take. The original text comes back
  /// when it fails or runs out of time.
  private func english(for text: String, improve: Bool = false) async -> String {
    let out: String? = await withDeadline(improve ? 75 : 15, fallback: nil) { [translator] in
      await translator.english(for: text, improve: improve)
    }
    guard let out else {
      // out of time: whatever is still waiting on the system translator is let go
      translator.abandonPending("переводчик не ответил за 15 секунд")
      return text
    }
    return Self.pictureNumbers(out)
  }

  /// Editing models tell their input pictures apart as "image 1", "image 2"… The translator
  /// renders «картинка 2» as "picture 2", "photo 2" or "pic 2"; all of them become the one
  /// wording the model was taught.
  static func pictureNumbers(_ text: String) -> String {
    var out = text
    let rules = [
      (#"\b(?:pictures|photos|photographs|pics|images|illustrations|drawings)\s+(?=[1-9]\b)"#, "images "),
      (#"\b(?:picture|photo|photograph|pic|img|image|illustration|drawing)\s*(?:no\.?\s*|#\s*)?(?=[1-9]\b)"#, "image "),
    ]
    for (pattern, replacement) in rules {
      guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
      else { continue }
      out = regex.stringByReplacingMatches(
        in: out, range: NSRange(out.startIndex..., in: out), withTemplate: replacement)
    }
    return out
  }

  /// What the model should read for `text`: the English made from exactly this text with the
  /// «Перевести» or «Улучшить» button, otherwise the text as written. Models with a Qwen
  /// encoder (Krea 2, Qwen Image, FLUX.2, Z-Image) read Russian as it is.
  private func modelText(for text: String) async -> String {
    if text == englishSource, !englishPrompt.isEmpty { return englishPrompt }
    return text
  }

  /// The negative prompt needs the same treatment as the positive one; models read it in
  /// English too.
  func translateNegative() {
    let text = negative.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, !translatingNegative else { return }
    translatingNegative = true
    Task {
      let out = await english(for: text)
      if out != text, negative.trimmingCharacters(in: .whitespacesAndNewlines) == text {
        negative = out
      }
      translatingNegative = false
    }
  }


  // MARK: generation

  /// One picture or one clip, with everything it needs captured the moment the button was
  /// pressed. Settings changed afterwards apply to the next press, not to work that is
  /// already waiting — that is what "добавить в очередь" promises.
  private enum Job {
    case image(ImageJob)
    case video(VideoJob)
  }

  private struct ImageJob {
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

  private struct VideoJob {
    var request: VideoRequest
    var suffix: String
    var fps: Int
    var format: VideoWriter.Format
  }

  private var queue: [Job] = []
  /// Which kind of work is running, so each tab shows only its own progress.
  @Published private(set) var running: Tab?
  /// Bumped by every new worker and every cancel. A cancelled run can take a moment to
  /// unwind; once it no longer holds the current number it may not touch the window.
  private var runID = 0

  private var engineKey: String { engineHost.host + String(engineHost.port) }

  private static let stampFormat: DateFormatter = {
    let format = DateFormatter()
    format.locale = Locale(identifier: "en_US_POSIX")
    format.dateFormat = "yyyyMMdd-HHmmss-SSS"
    return format
  }()

  private func outputURL(_ fileExtension: String) -> URL {
    outDir.appendingPathComponent(Self.stampFormat.string(from: Date()) + "." + fileExtension)
  }

  private var presetSuffix: String {
    presets.first(where: { $0.id == chosenPreset })?.suffix ?? ""
  }

  private static func randomSeed() -> UInt32 { UInt32.random(in: 0...UInt32(Int32.max)) }

  func enqueue() {
    guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
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

  private func makeImageJobs() -> [ImageJob] {
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
    let first = seedLocked ? lockedSeed : Self.randomSeed()
    return (0..<max(1, batch)).map { index in
      var request = base
      // A locked seed with a batch of four still gives four different pictures, each one
      // stepping the seed on by one, so the whole batch can be made again exactly.
      request.seed =
        seedLocked ? first &+ UInt32(index) : (index == 0 ? first : Self.randomSeed())
      return ImageJob(
        request: request, suffix: presetSuffix, modelName: name,
        exactSteps: pro ? proSteps : nil, quality: quality, savedSteps: savedForModel?.steps)
    }
  }

  /// The edit tab's run: the picture, the painted mask, the borrowed pictures and ControlNets.
  /// nil when there is no picture to edit.
  private func makeEditJobs() -> [ImageJob]? {
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
    let first = seedLocked ? lockedSeed : Self.randomSeed()
    return (0..<max(1, batch)).map { index in
      var request = base
      request.seed =
        seedLocked ? first &+ UInt32(index) : (index == 0 ? first : Self.randomSeed())
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

  private func makeVideoJob() -> VideoJob? {
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
      seed: seedLocked ? lockedSeed : Self.randomSeed(), cfg: videoCFG, sampler: videoSampler,
      shift: videoShift, inputs: inputs, parts: partsInUse(for: videoEntry),
      tweaks: tweaksInUse(for: videoEntry, masked: false), refiner: videoRefinerInUse?.file,
      refinerStart: Float(videoRefinerStart),
      takesImage: takesImageOverridden ? videoTakesImage : nil)
    return VideoJob(request: request, suffix: presetSuffix, fps: videoFPS, format: videoFormat)
  }

  private func startWorker() {
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

  private func drain(_ id: Int) async {
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

  private func progress(_ id: Int) -> @Sendable (Int, Int) -> Void {
    { [weak self] step, total in
      Task { @MainActor in
        guard let self, self.runID == id else { return }
        self.stepText = "шаг \(step) из \(total)"
        self.stepFraction = Double(step) / Double(max(1, total))
      }
    }
  }

  /// nil while the progress preview is switched off, so nothing is decoded for it.
  private func preview(_ id: Int) -> (@Sendable (PreviewBox) -> Void)? {
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
  private func open(_ model: String, _ id: Int) async -> Recommended? {
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

  private func failed(_ title: String, _ error: Error, _ id: Int) -> Bool {
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
  private func runImage(_ job: ImageJob, _ id: Int) async -> Bool {
    running = job.tab
    livePreview = nil
    var request = job.request
    let text = await modelText(for: request.prompt)
    guard id == runID, !Task.isCancelled else { return true }
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
  private func runVideo(_ job: VideoJob, _ id: Int) async -> Bool {
    running = .video
    livePreview = nil
    var request = job.request
    let text = await modelText(for: request.prompt)
    guard id == runID, !Task.isCancelled else { return true }
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

  // MARK: notices

  func notify(_ notice: Notice) {
    notices.removeAll { $0.title == notice.title }
    notices.append(notice)
    if notices.count > 3 { notices.removeFirst(notices.count - 3) }
    // a notice with nothing to press only informs, so it leaves by itself
    if notice.actions.isEmpty {
      let id = notice.id
      Task { [weak self] in
        try? await Task.sleep(nanoseconds: 7_000_000_000)
        self?.notices.removeAll { $0.id == id }
      }
    }
  }

  func dismiss(_ notice: Notice) {
    notices.removeAll { $0.id == notice.id }
  }

  nonisolated static func capitalized(_ text: String) -> String {
    text.prefix(1).uppercased() + text.dropFirst()
  }

  private func modelFailed(_ error: Error) -> Notice {
    Notice(
      title: "Модель не открылась",
      message: Self.capitalized(error.localizedDescription),
      actions: [.init("Перезапустить движок", .restartEngine), .init("Модели…", .openModels)])
  }

  private func report(_ problem: Translator.Problem) {
    switch problem {
    case .providerFailed(let engine, let reason):
      notify(
        Notice(
          title: "\(engine.label) не перевёл",
          message: "Prompt переведён через Apple." + (reason.isEmpty ? "" : " Причина: \(reason)"),
          actions: [.init("Переводить через Apple", .useTranslator(.system))]))
    case .translationFailed:
      var actions: [Notice.Choice] = []
      if translator.engine != .google {
        actions.append(.init("Через Google", .useTranslator(.google)))
      }
      actions.append(.init("Повторить", .retryTranslation))
      notify(
        Notice(title: "Перевести не удалось", message: "Prompt остался как написан", actions: actions))
    case .enrichFailed(let reason):
      notify(
        Notice(
          title: "Улучшить не удалось",
          message: "Prompt только переведён. " + Self.capitalized(reason),
          actions: [.init("Настройки улучшения", .openSettings(.translation))]))
    }
  }

  // MARK: leafing through results

  /// ← and → go through the results in fullscreen, or while the pointer is over the picture and
  /// nothing is being typed; Esc leaves fullscreen.
  func installKeyMonitor() {
    guard keyMonitor == nil else { return }
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      MainActor.assumeIsolated {
        guard let self else { return event }
        switch event.keyCode {
        case 53 where self.fullscreen != nil:
          self.fullscreen = nil
          return nil
        case 123, 124:
          let typing = NSApp.keyWindow?.firstResponder is NSText
          guard self.fullscreen != nil || (self.stageHovered && !typing) else { return event }
          self.step(through: event.keyCode == 123 ? 1 : -1)
          return nil
        default:
          return event
        }
      }
    }
  }

  /// Newest results come first, so going left means going back in time.
  func step(through offset: Int) {
    guard !frames.isEmpty else { return }
    let current = fullscreen ?? selected
    let index = current.flatMap { frame in frames.firstIndex { $0.id == frame.id } } ?? 0
    let next = min(max(index + offset, 0), frames.count - 1)
    let frame = frames[next]
    selected = frame
    gridMode = false
    if fullscreen != nil { fullscreen = frame }
    revealHUD()
  }

  func position(of frame: Frame) -> String {
    guard let index = frames.firstIndex(where: { $0.id == frame.id }) else { return "" }
    return "\(frames.count - index) из \(frames.count)"
  }

  // MARK: overlay

  func revealHUD() {
    hudTask?.cancel()
    hudShown = true
    guard hudMode == .auto else {
      hudShown = hudMode == .always
      return
    }
    hudTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 300_000_000)
      guard !Task.isCancelled else { return }
      await MainActor.run { self?.hudShown = false }
    }
  }

  func hoverHUD(_ inside: Bool) {
    guard hudMode == .auto else { return }
    if inside {
      hudTask?.cancel()
      hudShown = true
    } else {
      revealHUD()
    }
  }

  func setHUDMode(_ m: HUDMode) {
    hudMode = m
    switch m {
    case .always: hudTask?.cancel(); hudShown = true
    case .never: hudTask?.cancel(); hudShown = false
    case .auto: revealHUD()
    }
  }

  // MARK: memory and folders

  func unload() {
    guard !busy else {
      status = "дождитесь конца генерации"
      return
    }
    Task {
      let cap = MediaGenerationEnvironment.default.maxTotalWeightsCacheSize
      MediaGenerationEnvironment.default.maxTotalWeightsCacheSize = 0
      await engine.release()
      MediaGenerationEnvironment.default.maxTotalWeightsCacheSize = cap
      // The weights live in the engine, a separate program. Restarting it is the only sure
      // way to hand that memory back.
      if self.engineHost.running {
        self.engineHost.stop()
        try? await Task.sleep(nanoseconds: 500_000_000)
        self.engineHost.start(modelsDir: self.modelsDir)
      }
      await MainActor.run {
        self.status = "выгружено"
        self.refreshMemory()
      }
    }
  }

  func setCache(_ gb: Double) {
    cacheGB = gb
    MediaGenerationEnvironment.default.maxTotalWeightsCacheSize = UInt64(gb * 1_073_741_824)
    UserDefaults.standard.set(gb, forKey: "engine.cacheGB")
  }

  var modelsDir: URL { ModelsFolder.url }

  /// The folder holds one model plus its helpers: the picture decoder and the text
  /// encoder. Only the actual models belong in the picker, so the helpers are filtered out
  /// by name and by size — a text encoder is never the thing you choose to paint with.
  /// Opening a different model means different recommendations; fetch them straight away
  /// so the sidebar can show what it is about to use.
  func modelChanged() {
    recommended = nil
    savedForModel = ModelPrefs.load(model)
    refreshSpeedProfile()
    let wanted = model
    Task { [weak self] in
      guard let self, self.engineHost.ready else { return }
      do {
        let r = try await self.engine.prepare(
          model: wanted, backend: self.engineHost.backend, key: self.engineKey)
        self.tweakDefaults[wanted] = r.defaults
        guard self.model == wanted else { return }
        self.recommended = r
        if self.pro {
          let use = self.savedForModel ?? r
          self.proSteps = use.steps
          self.proCFG = use.cfg
          self.sampler = use.sampler
        }
      } catch {
        guard self.model == wanted else { return }
        self.status = "модель не открылась: \(error.localizedDescription)"
        self.notify(self.modelFailed(error))
      }
    }
  }

  var loraFiles: [InstalledModel] { library.loras }

  func addLoRA() {
    let used = Set(loraPicks.map(\.file))
    guard let next = loraFiles.first(where: { !used.contains($0.file) }) ?? loraFiles.first
    else { return }
    loraPicks.append(LoRAPick(file: next.file))
  }

  func removeLoRA(_ pick: LoRAPick) {
    loraPicks.removeAll { $0.id == pick.id }
  }

  func setLoRA(_ pick: LoRAPick, file: String) {
    guard let i = loraPicks.firstIndex(where: { $0.id == pick.id }) else { return }
    loraPicks[i].file = file
  }

  func setLoRAWeight(_ pick: LoRAPick, _ weight: Double) {
    guard let i = loraPicks.firstIndex(where: { $0.id == pick.id }) else { return }
    loraPicks[i].weight = weight
  }

  /// Family of the selected model, handed to the converter for LoRAs that do not say which
  /// model they were trained for.
  var currentFamily: String? {
    if let family = library.installed.first(where: { $0.file == model })?.family, !family.isEmpty {
      return family
    }
    if let raw = CatalogCache.rawFamily(of: model) { return raw }
    if let raw = CustomModels.entries(in: modelsDir)[model]?.version, !raw.isEmpty { return raw }
    // Models the public catalog no longer lists are still known to the engine itself, which
    // answers with a human label; that label is turned back into the raw family name.
    guard
      let label = (try? MediaGenerationEnvironment.default.resolveModel(model, offline: true))?
        .version
    else { return nil }
    return FamilyNames.rawByLabel[label]
  }

  var effectiveLoRAs: [LoRA]? {
    guard pro, loraOn, !loraPicks.isEmpty else { return nil }
    return loraPicks.map { LoRA(file: $0.file, weight: Float32($0.weight)) }
  }

  // MARK: upscaler

  var upscalerReady: Bool { library.installed.contains { $0.file == upscaler } }
  var upscaleJob: ImportJob? { library.jobs.first { $0.source.lastPathComponent == upscaler } }

  /// The factor in effect: the chosen one, or the model's own when none was chosen.
  var effectiveFactor: Int {
    upscaleFactor == 0 ? (Upscalers.model(upscaler)?.native ?? 4) : upscaleFactor
  }

  var effectiveUpscale: (file: String, factor: Int)? {
    guard upscaleOn, upscalerReady else { return nil }
    return (upscaler, effectiveFactor)
  }

  var upscaledSizeLabel: String {
    let (w, h) = effectiveSize
    return "→ \(w * effectiveFactor)×\(h * effectiveFactor)"
  }

  func setUpscale(_ on: Bool) {
    upscaleOn = on
    if on { ensureUpscaler() }
  }

  func chooseUpscaler(_ file: String) {
    upscaler = file
    upscaleFactor = 0
    ensureUpscaler()
  }

  /// Upscalers are small, so the chosen one is simply fetched rather than asked about.
  func ensureUpscaler() {
    guard !upscalerReady, let model = Upscalers.model(upscaler) else { return }
    library.fetch(model)
  }

  /// Video models are kept out of the picture picker and the other way round: choosing
  /// Wan on the image tab can only ever disappoint.
  var models: [InstalledModel] {
    library.checkpoints.filter { !VideoFamily.isVideo($0.family) }
  }
  var videoModels: [InstalledModel] {
    library.checkpoints.filter { VideoFamily.isVideo($0.family) }
  }

  func selectModel(_ file: String) {
    guard model != file else { return }
    model = file
    modelChanged()
  }

  /// Keeps the selection pointing at something that exists after the folder changed.
  func syncWithLibrary() {
    if !models.contains(where: { $0.file == model }), let first = models.first {
      model = first.file
      modelChanged()
    }
    if !videoModels.contains(where: { $0.file == videoModel }) {
      let next = videoModels.first?.file ?? ""
      if next != videoModel {
        videoModel = next
        videoModelChanged()
      }
    }
    let present = Set(library.loras.map(\.file))
    loraPicks.removeAll { !present.contains($0.file) }
  }

  // MARK: video settings

  var videoEntry: InstalledModel? { videoModels.first(where: { $0.file == videoModel }) }
  var videoFamily: VideoFamily? { videoEntry.flatMap { VideoFamily.of($0.family) } }
  var videoSizes: [VideoSize] { videoFamily?.sizes ?? VideoFamily.wanSmall.sizes }
  var videoSize: VideoSize {
    if videoPro, let custom = videoCustomSize { return custom }
    let list = videoSizes
    return list[min(max(0, videoSizeIndex), list.count - 1)]
  }

  func setVideoCustomSize(width: Int, height: Int) {
    func snap(_ v: Int) -> Int { min(2048, max(256, Int((Double(v) / 64).rounded()) * 64)) }
    if !videoPro { videoPro = true }
    videoCustomSize = VideoSize(width: snap(width), height: snap(height), shape: "своё")
  }

  /// The first frame's own shape at about the pixels of the model's size, in 64-pixel steps.
  func fitVideoSizeToFrame() {
    guard let url = videoFirstFrame?.url,
      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let pw = props[kCGImagePropertyPixelWidth] as? Int,
      let ph = props[kCGImagePropertyPixelHeight] as? Int, pw > 0, ph > 0
    else { return }
    let base = videoSizes[min(max(0, videoSizeIndex), videoSizes.count - 1)]
    let area = Double(base.width * base.height)
    let ratio = Double(pw) / Double(ph)
    var best: (w: Int, h: Int, score: Double)?
    for w in stride(from: 256, through: 2048, by: 64) {
      let h = min(2048, max(256, Int((Double(w) / ratio / 64).rounded()) * 64))
      let score = abs(log((Double(w) / Double(h)) / ratio)) * 4 + abs(log(Double(w * h) / area))
      if score < best?.score ?? .infinity { best = (w, h, score) }
    }
    guard let best else { return }
    setVideoCustomSize(width: best.w, height: best.h)
    status = "размер \(best.w)×\(best.h) — по первому кадру \(pw)×\(ph)"
  }
  var videoFrames: Int {
    guard let family = videoFamily else { return 49 }
    return family.frames(forSeconds: videoSeconds, fps: videoFPS)
  }
  var videoLengthLabel: String {
    String(
      format: "%.1f с · %d кадров · %d к/с", Double(videoFrames) / Double(max(1, videoFPS)),
      videoFrames, videoFPS)
  }
  var videoFixedLength: Bool { videoFamily?.fixedFrames != nil }

  /// Whether this model animates a picture you hand it, or works from the prompt alone.
  /// Whether the video model animates a picture: what the person said, else what its
  /// description and name say.
  var videoTakesImage: Bool {
    guard let entry = videoEntry else { return false }
    return ImageInputPrefs.stored(entry.file) ?? entry.takesImage
  }

  /// The person's own word on it, against the app's guess.
  func setTakesImage(_ value: Bool?) {
    guard let entry = videoEntry else { return }
    objectWillChange.send()
    ImageInputPrefs.save(value == entry.takesImage ? nil : value, for: entry.file)
  }

  var takesImageOverridden: Bool { videoEntry.map { ImageInputPrefs.stored($0.file) != nil } ?? false }

  // MARK: swapped parts

  struct PartChoice: Identifiable {
    let slot: ModelParts.Slot
    /// The standard file the model uses in this slot.
    let stock: String
    let options: [InstalledModel]
    var id: ModelParts.Slot { slot }
  }

  /// Every swappable part of this model, in a fixed order, with the added copies that fit it
  /// (possibly none: the menu still says what the model uses and offers to add one).
  func partSlots(for entry: InstalledModel?) -> [PartChoice] {
    guard let entry else { return [] }
    return ModelParts.Slot.allCases.compactMap { slot in
      guard let stock = entry.parts[slot] else { return nil }
      let options = library.parts.filter { $0.part?.slot == slot && $0.part?.stock == stock }
      return PartChoice(slot: slot, stock: stock, options: options)
    }
  }

  /// Picks a .safetensors and hands it to the models window, which works out what it is.
  func addPartFile() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [UTType(filenameExtension: "safetensors") ?? .data]
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.message = "выберите VAE или кодировщик в .safetensors — дообученную копию стандартного"
    guard panel.runModal() == .OK, let url = panel.urls.first else { return }
    library.add([url])
    status = "сверяю «\(url.lastPathComponent)» со стандартными частями — ход в окне «Модели»"
  }

  /// The added part chosen for this slot, if it is still there and still fits the model.
  func chosenPart(_ slot: ModelParts.Slot, for entry: InstalledModel?) -> InstalledModel? {
    guard let entry, let file = PartPrefs.stored(entry.file)[slot] else { return nil }
    return partSlots(for: entry).first { $0.slot == slot }?.options.first { $0.file == file }
  }

  /// nil goes back to the standard part.
  func choosePart(_ file: String?, _ slot: ModelParts.Slot, for entry: InstalledModel?) {
    guard let entry else { return }
    objectWillChange.send()
    PartPrefs.save(file, slot, for: entry.file)
  }

  func partsInUse(for entry: InstalledModel?) -> [ModelParts.Slot: String] {
    var out: [ModelParts.Slot: String] = [:]
    for item in partSlots(for: entry) {
      if let chosen = chosenPart(item.slot, for: entry) { out[item.slot] = chosen.file }
    }
    return out
  }

  /// "VAE: имя" for each swapped part, for the strips along the bottom.
  func partsLabel(for entry: InstalledModel?) -> [String] {
    partSlots(for: entry).compactMap { item in
      chosenPart(item.slot, for: entry).map { "\(item.slot.title): \($0.name)" }
    }
  }

  /// Whether this model can also be told where the clip should end.
  var videoTakesLastFrame: Bool { videoEntry?.modifier == "fl2va" }

  func frame(_ slot: FrameSlot) -> Reference? {
    slot == .first ? videoFirstFrame : videoLastFrame
  }

  func pickFrame(_ slot: FrameSlot) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.image]
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.message = "выберите \(slot.label)"
    guard panel.runModal() == .OK, let url = panel.urls.first else { return }
    setFrame(url, slot)
  }

  func setFrame(_ url: URL, _ slot: FrameSlot) {
    guard let image = Thumbnail.make(url) else {
      notify(
        Notice(
          title: "Картинка не открылась",
          message: "\(url.lastPathComponent) — формат, который система не читает"))
      return
    }
    let reference = Reference(url: url, role: slot == .first ? .source : .moodboard, thumb: image)
    switch slot {
    case .first:
      videoFirstFrame = reference
      matchSize(to: image)
    case .last:
      videoLastFrame = reference
      // the clip's shape follows the first frame; the last one only sets it when alone
      if videoFirstFrame == nil { matchSize(to: image) }
    }
  }

  func clearFrame(_ slot: FrameSlot) {
    switch slot {
    case .first: videoFirstFrame = nil
    case .last: videoLastFrame = nil
    }
  }

  /// "Анимировать" on the picture tab: the picture goes to the video tab as a frame.
  func animate(_ frame: Frame, as slot: FrameSlot) {
    setFrame(frame.url, slot)
    tab = .video
    guard !videoModels.isEmpty else {
      notify(
        Notice(
          title: "Кадр на месте, модели нет",
          message: "Чтобы оживить картинку, скачайте видеомодель — начните с Wan 2.1 1.3B Fun InP",
          actions: [.init("Модели…", .openModels)]))
      return
    }
    if slot == .first, !videoTakesImage, let model = videoEntry {
      status = "\(model.name) рисует только по Prompt — выберите модель, которая оживляет картинку"
    } else if slot == .last, !videoTakesLastFrame {
      status = "последний кадр поймёт только модель «первый и последний кадр»"
    } else {
      status = "\(slot.label) на вкладке видео"
    }
  }

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
  @Published private(set) var maskPainted = false
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

  func pickEditRef() {
    if let url = pickImage("выберите картинку, из которой взять лицо, костюм или стиль") {
      addEditRef(url)
    }
  }

  private func pickImage(_ message: String) -> URL? {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.image]
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.message = message
    return panel.runModal() == .OK ? panel.urls.first : nil
  }

  private func reference(_ url: URL, _ role: RefRole) -> Reference? {
    guard let thumb = Thumbnail.make(url) else {
      notify(
        Notice(
          title: "Картинка не открылась",
          message: "\(url.lastPathComponent) — формат, который система не читает"))
      return nil
    }
    return Reference(url: url, role: role, thumb: thumb)
  }

  func setEditSource(_ url: URL) {
    guard let picked = reference(url, .source) else { return }
    editSource = picked
    editRefs.removeAll { $0.url == url }
    // a mask belongs to the picture it was painted on, and so do the zones' boxes
    editMask = nil
    editRegions = []
    editShowResult = false
    matchAspect(to: picked.thumb)
  }

  func clearEditSource() {
    editSource = nil
    editMask = nil
    editShowResult = false
  }

  func addEditRef(_ url: URL) {
    guard !editRefs.contains(where: { $0.url == url }), editSource?.url != url,
      let picked = reference(url, .moodboard)
    else { return }
    if editRefs.count >= Self.maxEditRefs { editRefs.removeFirst() }
    editRefs.append(picked)
  }

  func removeEditRef(_ ref: Reference) { editRefs.removeAll { $0.id == ref.id } }

  /// An edit keeps the picture's shape unless told otherwise; a portrait squeezed into a
  /// square comes back with its subject cropped.
  private func matchAspect(to image: NSImage) {
    guard let rep = image.representations.first, rep.pixelsHigh > 0 else { return }
    let ratio = Double(rep.pixelsWide) / Double(rep.pixelsHigh)
    guard let best = Aspect.allCases.min(by: { abs($0.ratio - ratio) < abs($1.ratio - ratio) })
    else { return }
    aspect = best
    if pro {
      let (w, h) = megapixels.size(for: best)
      proWidth = w
      proHeight = h
      widthText = String(w)
      heightText = String(h)
    }
  }

  /// A short instruction added to the prompt from a chip under the edit box.
  func addToPrompt(_ phrase: String) {
    let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.localizedCaseInsensitiveContains(phrase) else { return }
    prompt = trimmed.isEmpty ? phrase : trimmed + ", " + phrase
  }

  /// "Редактировать" on a finished picture: it goes to the edit tab as the picture to change.
  func edit(_ frame: Frame) {
    tab = .edit
    setEditSource(frame.url)
  }

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

  private nonisolated static let stillCount = 12

  private func addStill(_ url: URL) {
    guard let thumb = Thumbnail.make(url, maxPixel: 256) else { return }
    recentStills.removeAll { $0.url == url }
    recentStills.insert(Still(url: url, thumb: thumb), at: 0)
    if recentStills.count > Self.stillCount { recentStills.removeLast() }
  }

  /// A vertical photo should not quietly become a wide clip with the sides cut off, so
  /// the size that fits it best is picked as soon as the picture arrives.
  private func matchSize(to image: NSImage) {
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
      for entry in [modelEntry, videoEntry].compactMap({ $0 }) where entry.parts[part.slot] == part.stock {
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

  private func engineHooks() -> EngineHooks {
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

  private func pauseEngine() async {
    await engine.release()
    engineHost.stop()
    status = "движок на паузе: конвертирую модель"
  }

  private func resumeEngine(selecting made: String?, replacing: String?, wasRunning: Bool) async {
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

  /// What the user saved for the current model. It replaces the model's own recommendation
  /// in both modes: simple mode sends it too.
  @Published var savedForModel: Recommended?

  func saveForModel() {
    let settings = Recommended(steps: proSteps, cfg: proCFG, sampler: sampler)
    ModelPrefs.save(settings, for: model)
    savedForModel = settings
    status = "настройки запомнены для этой модели"
  }

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

  private struct Session: Codable {
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
      UserDefaults.standard.set(data, forKey: "session.last")
      lastSavedSession = data
    }
  }

  private var lastSavedSession: Data?

  private func restore() {
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
