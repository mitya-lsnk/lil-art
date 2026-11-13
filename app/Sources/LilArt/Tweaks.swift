import Foundation
import MediaGenerationKit
import ModelZoo

/// The engine's finer settings — seed mode, shift, tiling, hires fix, TeaCache and the rest —
/// each with the models it means something for. Which apply follows the engine itself: the
/// settings it records in a picture's metadata for that kind of model (`ImageConverter`), so a
/// switch that would do nothing is never shown.
///
/// Every value starts as the model's own recommendation and is kept per model once changed
/// (`TweakPrefs`); a run gets only the changed ones.
struct Tweak: Identifiable {
  enum Kind {
    case toggle
    case number(ClosedRange<Double>, step: Double, decimals: Int)
    case choice([(value: Double, label: String)])
  }

  let id: String
  let title: String
  let hint: String
  let kind: Kind
  /// Shown only while this toggle is on (TeaCache's threshold under TeaCache).
  var parent: String? = nil
  let applies: (ModelTraits) -> Bool
  let read: (MediaGenerationPipeline.Configuration) -> Double
  let write: (inout MediaGenerationPipeline.Configuration, Double) -> Void
}

/// What a model is, as far as the settings care.
struct ModelTraits {
  let file: String
  let family: String
  let video: Bool
  /// The run edits a picture through a painted mask.
  let masked: Bool
  let sampler: SamplerType?

  static let unetFamilies: Set<String> = [
    "v1", "v2", "sdxl_base_v0.9", "sdxl_refiner_v0.9", "ssd_1b", "svd_i2v", "kandinsky2.1",
    "wurstchen_v3.0_stage_b", "wurstchen_v3.0_stage_c",
  ]
  static let sdxlFamilies: Set<String> = ["sdxl_base_v0.9", "sdxl_refiner_v0.9", "ssd_1b"]

  /// The older UNet models; everything newer is a flow transformer with a noise shift.
  var unet: Bool { Self.unetFamilies.contains(family) }
  var sdxl: Bool { Self.sdxlFamilies.contains(family) }
  var clipSkip: Bool { ["v1", "v2", "sdxl_base_v0.9", "sdxl_refiner_v0.9", "ssd_1b"].contains(family) }
  var teaCache: Bool { ModelZoo.teaCacheCoefficientsForModel(file) != nil }
  var guidanceEmbed: Bool { ModelZoo.guidanceEmbedForModel(file) }
  var instructEditing: Bool { ModelZoo.modifierForModel(file) == .editing }
  var tcd: Bool { sampler == .TCD || sampler == .tCDTrailing }
}

enum Tweaks {
  private static func pixels(_ range: ClosedRange<Double> = 256...4096) -> Tweak.Kind {
    .number(range, step: 64, decimals: 0)
  }

  static let all: [Tweak] = [
    Tweak(
      id: "seedMode", title: "режим сида",
      hint: "как из числа Seed получается шум. Чтобы повторить картинку из другой программы, нужен её режим",
      kind: .choice([
        (0, "Legacy"), (1, "Torch CPU"), (2, "Scale Alike"), (3, "NVIDIA GPU"),
      ]),
      applies: { _ in true },
      read: { Double($0.seedMode.rawValue) },
      write: { $0.seedMode = SeedMode(rawValue: Int8($1)) ?? $0.seedMode }),
    Tweak(
      id: "shift", title: "shift",
      hint: "сдвиг расписания шума: выше — больше внимания общей форме, ниже — деталям",
      kind: .number(0.1...20, step: 0.05, decimals: 2),
      applies: { !$0.unet && !$0.video },
      read: { Double($0.shift) }, write: { $0.shift = Float($1) }),
    Tweak(
      id: "resolutionDependentShift", title: "shift по размеру",
      hint: "движок сам подбирает shift под размер картинки",
      kind: .toggle, applies: { !$0.unet },
      read: { $0.resolutionDependentShift ? 1 : 0 }, write: { $0.resolutionDependentShift = $1 > 0 }),
    Tweak(
      id: "cfgZeroStar", title: "CFG Zero*",
      hint: "поправка CFG для первых шагов: меньше пересвета и лишнего контраста при CFG больше 1",
      kind: .toggle, applies: { !$0.unet },
      read: { $0.cfgZeroStar ? 1 : 0 }, write: { $0.cfgZeroStar = $1 > 0 }),
    Tweak(
      id: "cfgZeroInitSteps", title: "CFG Zero*: первых шагов без CFG",
      hint: "сколько первых шагов идут вовсе без CFG",
      kind: .number(0...20, step: 1, decimals: 0), parent: "cfgZeroStar", applies: { !$0.unet },
      read: { Double($0.cfgZeroInitSteps) }, write: { $0.cfgZeroInitSteps = Int($1) }),
    Tweak(
      id: "clipSkip", title: "CLIP skip",
      hint: "сколько последних слоёв кодировщика пропустить; аниме-модели SD часто просят 2",
      kind: .number(1...12, step: 1, decimals: 0), applies: { $0.clipSkip },
      read: { Double($0.clipSkip) }, write: { $0.clipSkip = Int($1) }),
    Tweak(
      id: "sharpness", title: "резкость",
      hint: "подчёркивает детали в процессе, а не фильтром после; 0 — выключено",
      kind: .number(0...30, step: 0.5, decimals: 1), applies: { _ in true },
      read: { Double($0.sharpness) }, write: { $0.sharpness = Float($1) }),
    Tweak(
      id: "stochasticSamplingGamma", title: "случайность TCD",
      hint: "для сэмплера TCD: доля нового шума на каждом шаге",
      kind: .number(0...1, step: 0.05, decimals: 2), applies: { $0.tcd },
      read: { Double($0.stochasticSamplingGamma) }, write: { $0.stochasticSamplingGamma = Float($1) }),
    Tweak(
      id: "imageGuidanceScale", title: "сила исходника",
      hint: "насколько модель-инструкция держится исходной картинки",
      kind: .number(0...10, step: 0.1, decimals: 1), applies: { $0.instructEditing },
      read: { Double($0.imageGuidanceScale) }, write: { $0.imageGuidanceScale = Float($1) }),
    Tweak(
      id: "guidanceEmbed", title: "встроенный CFG",
      hint: "у FLUX dev CFG зашит в модель: это число и есть его сила",
      kind: .number(0...30, step: 0.1, decimals: 1), applies: { $0.guidanceEmbed },
      read: { Double($0.guidanceEmbed) }, write: { $0.guidanceEmbed = Float($1) }),
    Tweak(
      id: "speedUpWithGuidanceEmbed", title: "ускорить встроенным CFG",
      hint: "считать без второго прохода на негатив: вдвое быстрее, Negative prompt не действует",
      kind: .toggle, applies: { $0.guidanceEmbed },
      read: { $0.speedUpWithGuidanceEmbed ? 1 : 0 }, write: { $0.speedUpWithGuidanceEmbed = $1 > 0 }),
    Tweak(
      id: "teaCache", title: "TeaCache",
      hint: "пропускает шаги, мало меняющие картинку: заметно быстрее ценой мелких деталей",
      kind: .toggle, applies: { $0.teaCache },
      read: { $0.teaCache ? 1 : 0 }, write: { $0.teaCache = $1 > 0 }),
    Tweak(
      id: "teaCacheThreshold", title: "TeaCache: порог",
      hint: "выше — больше пропущенных шагов и быстрее",
      kind: .number(0...1, step: 0.01, decimals: 2), parent: "teaCache", applies: { $0.teaCache },
      read: { Double($0.teaCacheThreshold) }, write: { $0.teaCacheThreshold = Float($1) }),
    Tweak(
      id: "teaCacheStart", title: "TeaCache: с шага",
      hint: "первые шаги, где закладывается форма, лучше считать честно",
      kind: .number(0...60, step: 1, decimals: 0), parent: "teaCache", applies: { $0.teaCache },
      read: { Double($0.teaCacheStart) }, write: { $0.teaCacheStart = Int($1) }),
    Tweak(
      id: "teaCacheEnd", title: "TeaCache: до шага",
      hint: "отрицательное число — считать от конца: −1 значит до предпоследнего",
      kind: .number(-60...60, step: 1, decimals: 0), parent: "teaCache", applies: { $0.teaCache },
      read: { Double($0.teaCacheEnd) }, write: { $0.teaCacheEnd = Int($1) }),
    Tweak(
      id: "teaCacheMaxSkipSteps", title: "TeaCache: пропусков подряд",
      hint: "сколько шагов подряд можно пропустить",
      kind: .number(1...20, step: 1, decimals: 0), parent: "teaCache", applies: { $0.teaCache },
      read: { Double($0.teaCacheMaxSkipSteps) }, write: { $0.teaCacheMaxSkipSteps = Int($1) }),
    Tweak(
      id: "hiresFix", title: "hires fix",
      hint: "сначала маленькая картинка, потом увеличение с дорисовкой: меньше двойных лиц на больших размерах",
      kind: .toggle, applies: { !$0.video },
      read: { $0.hiresFix ? 1 : 0 }, write: { $0.hiresFix = $1 > 0 }),
    Tweak(
      id: "hiresFixWidth", title: "hires fix: ширина первого прохода",
      hint: "в пикселях", kind: pixels(), parent: "hiresFix", applies: { !$0.video },
      read: { Double($0.hiresFixWidth) }, write: { $0.hiresFixWidth = Int($1) }),
    Tweak(
      id: "hiresFixHeight", title: "hires fix: высота первого прохода",
      hint: "в пикселях", kind: pixels(), parent: "hiresFix", applies: { !$0.video },
      read: { Double($0.hiresFixHeight) }, write: { $0.hiresFixHeight = Int($1) }),
    Tweak(
      id: "hiresFixStrength", title: "hires fix: сила дорисовки",
      hint: "сколько второй проход меняет увеличенную картинку",
      kind: .number(0...1, step: 0.05, decimals: 2), parent: "hiresFix", applies: { !$0.video },
      read: { Double($0.hiresFixStrength) }, write: { $0.hiresFixStrength = Float($1) }),
    Tweak(
      id: "tiledDecoding", title: "декодировать по частям",
      hint: "VAE переводит большую картинку в пиксели кусками: меньше памяти, возможны еле видные швы",
      kind: .toggle, applies: { _ in true },
      read: { $0.tiledDecoding ? 1 : 0 }, write: { $0.tiledDecoding = $1 > 0 }),
    Tweak(
      id: "decodingTileWidth", title: "кусок: ширина", hint: "в пикселях", kind: pixels(),
      parent: "tiledDecoding", applies: { _ in true },
      read: { Double($0.decodingTileWidth) }, write: { $0.decodingTileWidth = Int($1) }),
    Tweak(
      id: "decodingTileHeight", title: "кусок: высота", hint: "в пикселях", kind: pixels(),
      parent: "tiledDecoding", applies: { _ in true },
      read: { Double($0.decodingTileHeight) }, write: { $0.decodingTileHeight = Int($1) }),
    Tweak(
      id: "decodingTileOverlap", title: "кусок: перекрытие", hint: "в пикселях; больше — незаметнее швы",
      kind: pixels(64...1024), parent: "tiledDecoding", applies: { _ in true },
      read: { Double($0.decodingTileOverlap) }, write: { $0.decodingTileOverlap = Int($1) }),
    Tweak(
      id: "tiledDiffusion", title: "считать по частям",
      hint: "сама генерация идёт кусками: позволяет очень большие размеры, но куски могут не договориться",
      kind: .toggle, applies: { _ in true },
      read: { $0.tiledDiffusion ? 1 : 0 }, write: { $0.tiledDiffusion = $1 > 0 }),
    Tweak(
      id: "diffusionTileWidth", title: "часть: ширина", hint: "в пикселях", kind: pixels(),
      parent: "tiledDiffusion", applies: { _ in true },
      read: { Double($0.diffusionTileWidth) }, write: { $0.diffusionTileWidth = Int($1) }),
    Tweak(
      id: "diffusionTileHeight", title: "часть: высота", hint: "в пикселях", kind: pixels(),
      parent: "tiledDiffusion", applies: { _ in true },
      read: { Double($0.diffusionTileHeight) }, write: { $0.diffusionTileHeight = Int($1) }),
    Tweak(
      id: "diffusionTileOverlap", title: "часть: перекрытие", hint: "в пикселях",
      kind: pixels(64...1024), parent: "tiledDiffusion", applies: { _ in true },
      read: { Double($0.diffusionTileOverlap) }, write: { $0.diffusionTileOverlap = Int($1) }),
    Tweak(
      id: "maskBlur", title: "размытие края маски",
      hint: "плавный переход между перерисованным и нетронутым", kind: .number(0...30, step: 0.5, decimals: 1),
      applies: { $0.masked },
      read: { Double($0.maskBlur) }, write: { $0.maskBlur = Float($1) }),
    Tweak(
      id: "maskBlurOutset", title: "расширить маску",
      hint: "в пикселях; отрицательное — сузить", kind: .number(-64...64, step: 1, decimals: 0),
      applies: { $0.masked },
      read: { Double($0.maskBlurOutset) }, write: { $0.maskBlurOutset = Int($1) }),
    Tweak(
      id: "preserveOriginalAfterInpaint", title: "вне маски — пиксель в пиксель",
      hint: "вернуть нетронутые места точно как в исходнике, без пересжатия через VAE",
      kind: .toggle, applies: { $0.masked },
      read: { $0.preserveOriginalAfterInpaint ? 1 : 0 }, write: { $0.preserveOriginalAfterInpaint = $1 > 0 }),
    Tweak(
      id: "zeroNegativePrompt", title: "пустой негатив — ноль",
      hint: "SDXL: пустой Negative prompt считается как ничто, а не как пустая строка",
      kind: .toggle, applies: { $0.sdxl },
      read: { $0.zeroNegativePrompt ? 1 : 0 }, write: { $0.zeroNegativePrompt = $1 > 0 }),
    Tweak(
      id: "aestheticScore", title: "оценка красоты",
      hint: "SDXL: какую «оценку» просить у модели", kind: .number(0...10, step: 0.5, decimals: 1),
      applies: { $0.sdxl },
      read: { Double($0.aestheticScore) }, write: { $0.aestheticScore = Float($1) }),
    Tweak(
      id: "negativeAestheticScore", title: "оценка для негатива",
      hint: "SDXL: «оценка», от которой уходить", kind: .number(0...10, step: 0.5, decimals: 1),
      applies: { $0.sdxl },
      read: { Double($0.negativeAestheticScore) }, write: { $0.negativeAestheticScore = Float($1) }),
  ]

  static func visible(for traits: ModelTraits) -> [Tweak] { all.filter { $0.applies(traits) } }

  /// The model's own value for every setting, read once from its recommendation.
  static func defaults(from configuration: MediaGenerationPipeline.Configuration) -> [String: Double] {
    var out: [String: Double] = [:]
    for tweak in all { out[tweak.id] = tweak.read(configuration) }
    return out
  }

  /// Puts the changed values onto a run's configuration.
  static func apply(_ values: [String: Double], to configuration: inout MediaGenerationPipeline.Configuration) {
    for tweak in all {
      if let value = values[tweak.id] { tweak.write(&configuration, value) }
    }
  }
}

/// The values changed by hand, per model file.
enum TweakPrefs {
  private static let key = "model.tweaks"

  static func stored(_ model: String) -> [String: Double] {
    (LilStore.standard.dictionary(forKey: key) as? [String: [String: Double]])?[model] ?? [:]
  }

  static func save(_ value: Double?, _ id: String, for model: String) {
    var all = (LilStore.standard.dictionary(forKey: key) as? [String: [String: Double]]) ?? [:]
    var mine = all[model] ?? [:]
    mine[id] = value
    all[model] = mine.isEmpty ? nil : mine
    LilStore.standard.set(all, forKey: key)
  }

  static func clear(_ model: String) {
    var all = (LilStore.standard.dictionary(forKey: key) as? [String: [String: Double]]) ?? [:]
    all[model] = nil
    LilStore.standard.set(all, forKey: key)
  }
}
