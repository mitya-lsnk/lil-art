import Foundation
import MediaGenerationKit

/// The engine folds the noise schedule into the sampler name: Karras, Trailing, AYS and
/// Substep are schedules, not separate settings. Picking the wrong one is how a model ends
/// up producing mush, so all twenty are offered rather than a curated few.
enum Samplers {
  static let all: [(SamplerType, String)] = [
    (.eulerATrailing, "Euler A Trailing"),
    (.eulerA, "Euler A"),
    (.eulerAAYS, "Euler A AYS"),
    (.eulerASubstep, "Euler A Substep"),
    (.dPMPP2MKarras, "DPM++ 2M Karras"),
    (.dPMPP2MTrailing, "DPM++ 2M Trailing"),
    (.DPMPP2MAYS, "DPM++ 2M AYS"),
    (.dPMPPSDEKarras, "DPM++ SDE Karras"),
    (.dPMPPSDETrailing, "DPM++ SDE Trailing"),
    (.DPMPPSDEAYS, "DPM++ SDE AYS"),
    (.dPMPPSDESubstep, "DPM++ SDE Substep"),
    (.uniPC, "UniPC"),
    (.uniPCTrailing, "UniPC Trailing"),
    (.uniPCAYS, "UniPC AYS"),
    (.DDIM, "DDIM"),
    (.dDIMTrailing, "DDIM Trailing"),
    (.PLMS, "PLMS"),
    (.LCM, "LCM"),
    (.TCD, "TCD"),
    (.tCDTrailing, "TCD Trailing"),
  ]

  static func name(_ s: SamplerType) -> String {
    all.first(where: { $0.0 == s })?.1 ?? "\(s)"
  }

  /// Which models each schedule is actually meant for. The suffix is the schedule and
  /// picking the wrong one is how a good model produces mush.
  static func hint(for s: SamplerType) -> String {
    switch s {
    case .eulerATrailing, .dPMPP2MTrailing, .dPMPPSDETrailing, .uniPCTrailing, .dDIMTrailing:
      return "trailing: flux, sd3, qwen image. нужен всем, кто обучен с нулевым шумом в конце"
    case .tCDTrailing:
      return "trailing + tcd: только для моделей и лор с дистилляцией tcd"
    case .dPMPP2MKarras, .dPMPPSDEKarras:
      return "karras: sd 1.5, sdxl, pony, illustrious. проверенная классика"
    case .DPMPP2MAYS, .eulerAAYS, .DPMPPSDEAYS, .uniPCAYS:
      return "ays: sdxl и sd 1.5 на коротких прогонах, 8-12 шагов"
    case .LCM:
      return "только для lcm-моделей и lcm-лор. на обычной модели даст кашу"
    case .TCD:
      return "только для tcd-моделей. на обычной модели даст кашу"
    case .eulerASubstep, .dPMPPSDESubstep:
      return "substep: дробит шаги, помогает когда шагов мало, 4-10"
    case .eulerA:
      return "euler a: sd 1.5 и sdxl, мягкий и вариативный"
    case .DDIM:
      return "ddim: старый и предсказуемый, для совместимости со старыми рецептами"
    case .PLMS:
      return "plms: очень старый, почти не нужен"
    case .uniPC:
      return "unipc: sdxl, быстро сходится на 15-20 шагах"
    default:
      return "универсальный"
    }
  }
}

/// A rough but measured guess at how much memory a run will want, so nobody types 12
/// megapixels and watches the machine swap itself to death.
/// Measured on this machine (M5 Pro, flux 2 klein, 4 steps):
///   1.05 МП → 2.4 ГБ / 11.5 с · 1.98 МП → 4.3 ГБ / 22.8 с · 4.19 МП → 5.0 ГБ / 55.1 с
/// Memory flattens out because the weights are mapped from disk; time does not, so the
/// clock is usually the thing worth warning about.
enum Budget {
  static let baseGB = 2.13
  static let perMegapixelGB = 0.74
  static let secondsPerMegapixel = 13.9
  static let baseSeconds = -3.0

  static func megapixels(_ w: Int, _ h: Int) -> Double { Double(w * h) / 1_000_000 }

  /// Pictures in a batch are made one after another, so the batch size does not add to
  /// the memory any single one needs.
  static func memoryGB(width: Int, height: Int) -> Double {
    baseGB + perMegapixelGB * megapixels(width, height)
  }

  /// Seconds for one frame at the given size and step count.
  static func seconds(width: Int, height: Int, steps: Int) -> Double {
    let mp = megapixels(width, height)
    let atFourSteps = max(4, secondsPerMegapixel * mp + baseSeconds)
    return atFourSteps * Double(steps) / 4
  }

  enum Verdict {
    case fine, tight, tooMuch

    var label: String {
      switch self {
      case .fine: return "поместится"
      case .tight: return "впритык"
      case .tooMuch: return "не поместится"
      }
    }
  }

  static func verdict(needGB: Double, freeGB: Double) -> Verdict {
    if needGB > freeGB { return .tooMuch }
    if needGB > freeGB * 0.8 { return .tight }
    return .fine
  }

  static func humanTime(_ seconds: Double) -> String {
    if seconds < 60 { return String(format: "~%.0f с", seconds) }
    let m = Int(seconds) / 60
    let s = Int(seconds) % 60
    return s == 0 ? "~\(m) мин" : "~\(m) мин \(s) с"
  }
}

/// The engine refuses anything that is not a multiple of 64 on both sides
/// (MediaGenerationPipeline: "width and height must be multiples of 64"), so this is a
/// hard requirement, not a nicety.
func snapTo64(_ v: Int) -> Int { max(256, min(4096, Int((Double(v) / 64).rounded()) * 64)) }

/// Practical starting points, by model family. These are community defaults rather than
/// rules, which is why the text says "обычно".
enum Guidance {
  static let steps = """
    СКОЛЬКО ШАГОВ ОБЫЧНО СТАВЯТ

    flux klein, schnell, lcm, turbo, lightning — 2-8.
    Это ускоренные модели, больше шагов им не помогает.

    flux dev, sd3, qwen image — 20-28.

    sdxl, pony, illustrious, noobai — 25-35.

    sd 1.5 — 20-30.

    Больше шагов даёт больше мелких деталей и дольше считает.
    После определённого числа картинка почти не меняется.
    """

  static let cfg = """
    КАКОЙ CFG ОБЫЧНО СТАВЯТ

    flux klein, schnell — 1-2. Им подсказка почти не нужна.
    flux dev — 3-4.

    sdxl — 5-7.
    pony — около 7, он любит повыше.
    illustrious, noobai — 4-6.

    sd 1.5 — 7-8.

    lcm, turbo, lightning — 1-2, выше ломает картинку.

    Выше значит строже по тексту, но жёстче и контрастнее.
    Ниже значит свободнее и мягче.
    """
}

/// The catalog's own notes are English marketing plus a link. What a person actually needs
/// to know is what the family is for and what the letters after the size mean.
enum Describe {
  static func family(_ version: String) -> String {
    switch version {
    case "v1": return "Stable Diffusion 1.5. Старая, быстрая, огромная библиотека лор."
    case "v2": return "Stable Diffusion 2. Промежуточная, сейчас почти не нужна."
    case "sdxl_base_v0.9", "ssd_1b": return "SDXL. Рабочая лошадь, лучший выбор лор и стилей."
    case "sdxl_refiner_v0.9": return "Доводчик для SDXL, работает вторым проходом."
    case "sd3", "sd3_large": return "Stable Diffusion 3. Лучше держит текст на картинке."
    case "flux1": return "FLUX.1. Сильная анатомия и свет, любит мало шагов."
    case "flux2", "flux2_4b", "flux2_9b":
      return "FLUX.2. Свежее поколение, умеет править картинку по словесной инструкции."
    case "qwen_image": return "Qwen Image. Очень хорошо рисует надписи, в том числе не латиницей."
    case "hidream_i1": return "HiDream. Фотореализм."
    case "z_image": return "Z-Image. Компактная, быстрая."
    case "pixart", "auraflow": return "Исследовательские модели, на любителя."
    case "kandinsky2.1": return "Кандинский. Отечественная, понимает русский напрямую."
    case "wurstchen_v3.0_stage_c", "wurstchen_v3.0_stage_b":
      return "Würstchen. Экономная по памяти."
    case "svd_i2v": return "Stable Video Diffusion. Оживляет вашу картинку."
    case "hunyuan_video": return "Hunyuan Video. Видео из текста, требовательна."
    case "wan_v2.1_1.3b", "wan_v2.1_14b", "wan_v2.2_5b":
      return "Wan. Главное семейство для видео на маке, есть и из текста, и из картинки."
    case "ltx2", "ltx2.3": return "LTX. Видео, быстрое по сравнению с остальными."
    default: return ""
    }
  }

  /// Decodes the tail of a file name: this is what separates two models that otherwise
  /// look identical.
  static func suffixes(_ file: String) -> [String] {
    let n = file.lowercased()
    var out: [String] = []
    if n.contains("q4p") { out.append("4 бита — самая лёгкая, качество заметно ниже") }
    else if n.contains("q5p") { out.append("5 бит — лёгкая, качество чуть ниже") }
    else if n.contains("q6p") { out.append("6 бит — компромисс размера и качества") }
    else if n.contains("q8p") { out.append("8 бит — почти без потерь, обычный выбор") }
    else if n.contains("f16") { out.append("без сжатия — лучшее качество, самый большой файл") }
    if n.contains("svdquant") { out.append("SVDQuant — умнее сжимает, лучше на малых битах") }
    if n.contains("lightning") || n.contains("turbo") || n.contains("hyper") {
      out.append("ускоренная — 4-8 шагов вместо 25")
    }
    if n.contains("lcm") { out.append("LCM — 2-8 шагов, нужен сэмплер LCM") }
    if n.contains("_t2v") { out.append("из текста в видео") }
    if n.contains("_i2v") { out.append("из картинки в видео") }
    if n.contains("inpaint") { out.append("дорисовка по маске") }
    if n.contains("kontext") { out.append("правка картинки словами") }
    if n.contains("refiner") { out.append("доводчик, вторым проходом после основной") }
    return out
  }

  /// Strips the markdown link and the copyright tail out of the catalog note.
  static func clean(_ note: String) -> String {
    var t = note
    while let open = t.firstIndex(of: "["), let close = t[open...].firstIndex(of: "]") {
      let label = String(t[t.index(after: open)..<close])
      var end = t.index(after: close)
      if end < t.endIndex, t[end] == "(" {
        if let paren = t[end...].firstIndex(of: ")") { end = t.index(after: paren) }
      }
      t.replaceSubrange(open..<end, with: label)
    }
    return t.replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespaces)
  }
}

/// Sizes people reach for often, in the engine's own steps of 64.
enum SizePreset: CaseIterable {
  case square1k, landscape3x2, wide16x9, print4x5

  var label: String {
    switch self {
    case .square1k: return "1024²"
    case .landscape3x2: return "1216×832"
    case .wide16x9: return "1344×768"
    case .print4x5: return "1152×896"
    }
  }
  var size: (Int, Int) {
    switch self {
    case .square1k: return (1024, 1024)
    case .landscape3x2: return (1216, 832)
    case .wide16x9: return (1344, 768)
    case .print4x5: return (1152, 896)
    }
  }
}

/// The engine's own upscalers: ESRGAN-family networks run right after the picture, in the same
/// request. The files are small and live on the same server as the models.
enum Upscalers {
  struct Model: Hashable {
    let file: String
    let name: String
    /// The factor the network was trained for.
    let native: Int
    let megabytes: Int
    let hint: String
  }

  static let all: [Model] = [
    Model(
      file: "4x_ultrasharp_f16.ckpt", name: "4x UltraSharp", native: 4, megabytes: 32,
      hint: "фото и реализм: резкие мелкие детали, самый частый выбор"),
    Model(
      file: "remacri_4x_f16.ckpt", name: "Remacri", native: 4, megabytes: 32,
      hint: "фото: мягче UltraSharp, естественнее кожа и фактуры"),
    Model(
      file: "realesrgan_x4plus_f16.ckpt", name: "Real-ESRGAN X4+", native: 4, megabytes: 32,
      hint: "универсальный, заодно убирает артефакты сжатия"),
    Model(
      file: "realesrgan_x2plus_f16.ckpt", name: "Real-ESRGAN X2+", native: 2, megabytes: 32,
      hint: "обучен именно на ×2 — лучший выбор, когда нужно увеличить вдвое"),
    Model(
      file: "realesrgan_x4plus_anime_6b_f16.ckpt", name: "Real-ESRGAN X4+ Anime", native: 4,
      megabytes: 9, hint: "аниме и рисунок: чистые линии и ровные заливки"),
    Model(
      file: "esrgan_4x_universal_upscaler_v2_sharp_f16.ckpt", name: "UniversalUpscaler V2 Sharp",
      native: 4, megabytes: 32, hint: "универсальный с упором на резкость"),
  ]

  static func model(_ file: String) -> Model? { all.first { $0.file == file } }
}
