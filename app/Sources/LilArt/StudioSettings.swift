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
  // MARK: settings in effect

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
}
