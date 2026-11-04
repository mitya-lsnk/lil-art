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
