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
      await freeEngine()
      await MainActor.run {
        self.status = "выгружено"
        self.refreshMemory()
      }
    }
  }


  /// Hands the engine's memory back and starts it again empty.
  func freeEngine() async {
    let cap = MediaGenerationEnvironment.default.maxTotalWeightsCacheSize
    MediaGenerationEnvironment.default.maxTotalWeightsCacheSize = 0
    await engine.release()
    MediaGenerationEnvironment.default.maxTotalWeightsCacheSize = cap
    // The weights live in the engine, a separate program. Restarting it is the only sure
    // way to hand that memory back.
    if engineHost.running {
      // waited for: whoever asked for the memory must find it free when this returns
      await engineHost.stopAndWait()
      engineHost.start(modelsDir: modelsDir)
    }
  }


  func setCache(_ gb: Double) {
    cacheGB = gb
    MediaGenerationEnvironment.default.maxTotalWeightsCacheSize = UInt64(gb * 1_073_741_824)
    LilStore.standard.set(gb, forKey: "engine.cacheGB")
  }


  var modelsDir: URL { ModelsFolder.url }

  /// The folder holds one model plus its helpers: the picture decoder and the text
  /// encoder. Only the actual models belong in the picker, so the helpers are filtered out
  /// by name and by size — a text encoder is never the thing you choose to paint with.
  /// Opening a different model means different recommendations; fetch them straight away
  /// so the sidebar can show what it is about to use.
  func modelChanged() {
    recommended = nil
    // a bigger model leaves less room for kept copies
    if !busy { applyCache(cacheGB) }
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


  /// Everything about models (add, catalog, LoRAs, disk) lives on one page of the settings.
  func openModels(_ open: OpenWindowAction) {
    settingsPage = .models
    open(id: "settings")
  }

  var loraFiles: [InstalledModel] { library.loras }

  /// A pick lives in the picture list or in the video one; whoever holds it is changed.
  private func changePick(_ id: UUID, _ change: (inout LoRAPick) -> Void) {
    if let i = loraPicks.firstIndex(where: { $0.id == id }) { change(&loraPicks[i]) }
    if let i = videoLoraPicks.firstIndex(where: { $0.id == id }) { change(&videoLoraPicks[i]) }
  }

  func addLoRA(video: Bool = false) {
    let used = Set((video ? videoLoraPicks : loraPicks).map(\.file))
    guard let next = loraFiles.first(where: { !used.contains($0.file) }) ?? loraFiles.first
    else { return }
    let pick = LoRAPick(file: next.file, weight: LoRAPrefs.weight(for: next.file) ?? 0.6)
    if video { videoLoraPicks.append(pick) } else { loraPicks.append(pick) }
  }


  func removeLoRA(_ pick: LoRAPick) {
    loraPicks.removeAll { $0.id == pick.id }
    videoLoraPicks.removeAll { $0.id == pick.id }
  }


  func setLoRA(_ pick: LoRAPick, file: String) {
    changePick(pick.id) {
      $0.file = file
      // each LoRA comes back at the strength it was last used at
      if let saved = LoRAPrefs.weight(for: file) { $0.weight = saved }
    }
  }


  func setLoRAWeight(_ pick: LoRAPick, _ weight: Double) {
    changePick(pick.id) { $0.weight = weight }
    LoRAPrefs.setWeight(weight, for: pick.file)
  }


  func setLoRAStage(_ pick: LoRAPick, _ stage: LoRAStage) {
    changePick(pick.id) { $0.stage = stage }
  }


  func loraWords(_ file: String) -> String { LoRAPrefs.words(for: file) }

  func setLoRAWords(_ words: String, for file: String) {
    LoRAPrefs.setWords(words, for: file)
    objectWillChange.send()
  }

  /// The trigger words of the LoRAs in use, to go after the prompt; nothing already written
  /// there (or in its English) is repeated.
  var loraSuffix: String {
    guard effectiveLoRAs != nil else { return "" }
    return LoRAPrefs.suffix(
      words: loraPicks.filter { $0.weight != 0 }.map { LoRAPrefs.words(for: $0.file) },
      alreadyIn: [prompt, englishPrompt])
  }

  /// The LoRAs of the next clip. With two models each acts on the half it was given.
  var videoLoRAs: [LoRA]? {
    guard videoPro, videoLoraOn, !videoLoraPicks.isEmpty else { return nil }
    let paired = videoRefinerInUse != nil
    return videoLoraPicks.map { pick in
      let mode: LoRAMode = !paired ? .all : pick.stage == .high ? .base : pick.stage == .low ? .refiner : .all
      return LoRA(file: pick.file, weight: Float32(pick.weight), mode: mode)
    }
  }

  var videoLoraSuffix: String {
    guard videoLoRAs != nil else { return "" }
    return LoRAPrefs.suffix(
      words: videoLoraPicks.filter { $0.weight != 0 }.map { LoRAPrefs.words(for: $0.file) },
      alreadyIn: [prompt, englishPrompt])
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
