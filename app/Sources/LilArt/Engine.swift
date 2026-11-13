import AVFoundation
import AppKit
import Combine
import CoreGraphics
import Darwin
import Foundation
import MediaGenerationKit
import SwiftUI
import UniformTypeIdentifiers

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
    p.configuration.loras = Self.merge(r.loras, into: loaded.1)
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
final class OnceFlag: @unchecked Sendable {
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
