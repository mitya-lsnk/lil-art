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
  // MARK: swapped parts

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
}
