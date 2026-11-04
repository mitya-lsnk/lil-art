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
  // MARK: memory and folders

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
}
