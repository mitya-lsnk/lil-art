import CoreGraphics
import Foundation
import MediaGenerationKit
import UniformTypeIdentifiers

final class Counter: @unchecked Sendable {
  var previews = 0
  var lastStep = 0
}

/// Headless check of the engine. Usage:
///   Probe [--remote] [--model file] [--prompt text] [--seed n] [--size n]
///         [--lora file --weight w] [--out name]
/// Exactly the call the app makes in `Studio.currentFamily`: a plain function, so the
/// synchronous, offline overload is the one chosen, not the async one.
func familySync(_ file: String) -> String? {
  (try? MediaGenerationEnvironment.default.resolveModel(file, offline: true))?.version
}

/// Mirror of Studio.currentFamily: the cached public catalog first, then the engine's
/// label taken back through the same table the app uses.
let rawByLabel: [String: String] = [
  "Stable Diffusion v1": "v1", "Stable Diffusion XL Base": "sdxl_base_v0.9",
  "FLUX.1": "flux1", "FLUX.2": "flux2", "FLUX.2 9B": "flux2_9b", "FLUX.2 4B": "flux2_4b",
  "Qwen Image": "qwen_image", "Krea 2": "krea_2", "Ideogram 4": "ideogram_4",
]

func familyForApp(_ file: String) -> String? {
  let home = FileManager.default.homeDirectoryForCurrentUser
  for path in [home.appendingPathComponent("lil-art/cache/models.json").path, "/tmp/dtmodels.json"] {
    guard let data = FileManager.default.contents(atPath: path),
      let raw = try? JSONSerialization.jsonObject(with: data)
    else { continue }
    let list = (raw as? [[String: Any]]) ?? ((raw as? [String: Any])?["models"] as? [[String: Any]]) ?? []
    if let hit = list.first(where: { ($0["file"] as? String) == file }), let v = hit["version"] as? String {
      return v
    }
  }
  guard let label = familySync(file) else { return nil }
  return rawByLabel[label]
}

/// Builds a value of a String-backed enum from its raw value, given only its optional type.
func familyValue<T: RawRepresentable>(_: T?.Type, _ raw: String) -> T? where T.RawValue == String {
  T(rawValue: raw)
}

@main
struct Probe {
  static func value(_ flag: String) -> String? {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: flag), i + 1 < a.count else { return nil }
    return a[i + 1]
  }

  static func main() async {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let models = home.appendingPathComponent("lil-art/models")
    MediaGenerationEnvironment.default.externalUrls = [models]

    // --families: what the app will use as the fallback family for each installed model
    if CommandLine.arguments.contains("--families") {
      for file in ["krea_2_turbo_q8p.ckpt", "flux_2_klein_4b_q8p.ckpt", "deliberate_v2_q6p_q8p.ckpt"] {
        let raw = familyForApp(file)
        print("\(file) → ярлык движка: \(familySync(file) ?? "нет") · для импортёра: \(raw ?? "НЕ ОПРЕДЕЛИЛОСЬ")")
      }
      return
    }

    // --convert <file.safetensors> [--to <dir>]: the LoRA converter on its own, with timing
    if let path = value("--convert") {
      let source = URL(fileURLWithPath: path)
      let outDir = URL(fileURLWithPath: value("--to") ?? NSTemporaryDirectory())
      let dest = outDir.appendingPathComponent(
        source.deletingPathExtension().lastPathComponent.replacingOccurrences(of: " ", with: "_")
          + "_lora_f16.ckpt")
      print("конвертирую \(source.lastPathComponent)")
      let t0 = Date()
      var lastTen = -1
      do {
        var importer = LoRAImporter(file: source)
        if let raw = value("--version") {
          // The family enum lives in a module the kit does not re-export, but it is a plain
          // String enum, so a value can be made without ever naming the type.
          importer.version = familyValue(type(of: importer.version), raw)
          print(importer.version == nil ? "семейство \(raw) движку неизвестно" : "семейство задано вручную: \(raw)")
        }
        try importer.inspect()
        print(String(format: "семейство определено за %.1f с: ", Date().timeIntervalSince(t0))
          + String(describing: importer.version))
        try importer.import(to: dest) { fraction in
          let pct = Int(fraction * 100)
          if pct / 10 != lastTen {
            lastTen = pct / 10
            print(String(format: "  %3d%% · %.0f с", pct, Date().timeIntervalSince(t0)))
          }
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
        print(String(format: "OK · %.1f с · %.0f МБ · %@", Date().timeIntervalSince(t0),
                     Double(size) / 1_048_576, dest.path))
      } catch {
        print(String(format: "ОШИБКА через %.1f с: ", Date().timeIntervalSince(t0))
          + String(describing: error))
        exit(1)
      }
      return
    }

    // --dequant <file.safetensors> --to <out.safetensors>: unpack ComfyUI fp8-scaled weights
    if let path = value("--dequant"), let out = value("--to") {
      let t0 = Date()
      let source = URL(fileURLWithPath: path)
      print("нужно раскрывать: \(ScaledCheckpoint.needsDequantizing(source))")
      do {
        try ScaledCheckpoint.dequantize(source, to: URL(fileURLWithPath: out)) { _ in }
        let size = ((try? FileManager.default.attributesOfItem(atPath: out))?[.size] as? Int64) ?? 0
        print(String(format: "OK за %.1f с · %.2f ГБ", Date().timeIntervalSince(t0),
                     Double(size) / 1_073_741_824))
      } catch {
        print("ОШИБКА: " + String(describing: error))
        exit(1)
      }
      return
    }

    // --quantize <file.ckpt> --version <raw> --to <out.ckpt>: the 8-bit compressor on its own
    if let path = value("--quantize") {
      let out = value("--to") ?? (path + ".q8p.ckpt")
      let t0 = Date()
      do {
        try WeightCompressor.compress(input: path, output: out, version: value("--version") ?? "v1") { _ in }
        let size = ((try? FileManager.default.attributesOfItem(atPath: out))?[.size] as? Int64) ?? 0
        print(String(format: "OK за %.1f с · %.2f ГБ · %@", Date().timeIntervalSince(t0),
                     Double(size) / 1_073_741_824, out))
      } catch {
        print("ОШИБКА: " + String(describing: error))
        exit(1)
      }
      return
    }

    let remote = CommandLine.arguments.contains("--remote")
    let model = value("--model") ?? "flux_2_klein_4b_q8p.ckpt"
    let prompt = value("--prompt") ?? "brass seahorse macro, black velvet background"
    let seed = UInt32(value("--seed") ?? "") ?? 1234
    let size = Int(value("--size") ?? "") ?? 1024
    let out = value("--out") ?? "probe"
    let lora = value("--lora")
    let weight = Float(value("--weight") ?? "") ?? 0.8

    let backend: MediaGenerationPipeline.Backend =
      remote ? .remote(.init(host: "127.0.0.1", port: Int(value("--port") ?? "") ?? 7859)) : .local
    print("движок: \(remote ? "внешний" : "встроенный") · модель: \(model) · сид: \(seed)")
    if let lora { print("lora: \(lora) · сила \(weight)") }

    let box = Counter()
    do {
      var pipeline = try await MediaGenerationPipeline.fromPretrained(model, backend: backend)
      pipeline.configuration.width = Int(value("--width") ?? "") ?? size
      pipeline.configuration.height = Int(value("--height") ?? "") ?? size
      pipeline.configuration.seed = seed
      if let steps = Int(value("--steps") ?? "") { pipeline.configuration.steps = steps }
      if let cfg = Float(value("--cfg") ?? "") { pipeline.configuration.guidanceScale = cfg }
      if let raw = value("--sampler"),
        let sampler = SamplerType.allCases.first(where: { "\($0)" == raw })
      {
        pipeline.configuration.sampler = sampler
      }
      if let upscaler = value("--upscaler") {
        pipeline.configuration.upscaler = upscaler
        pipeline.configuration.upscalerScaleFactor = Int(value("--factor") ?? "") ?? 0
      }
      print(
        "рекомендация модели: \(pipeline.configuration.steps) шагов, cfg \(pipeline.configuration.guidanceScale), lora в шаблоне: \(pipeline.configuration.loras.count)"
      )
      if let lora {
        pipeline.configuration.loras = pipeline.configuration.loras + [LoRA(file: lora, weight: weight)]
      }
      let t0 = Date()
      let results = try await pipeline.generate(prompt: prompt, negativePrompt: "") {
        state, preview in
        if case let .generating(step, _) = state { box.lastStep = step }
        if let preview, preview.count > 0 {
          _ = preview[0]
          box.previews += 1
        }
      }
      let dt = Date().timeIntervalSince(t0)
      let file = home.appendingPathComponent("lil-art/\(out).png")
      try results[0].write(to: file, type: UTType.png)
      print(String(format: "OK · %.1f с · шагов %d · превью %d", dt, box.lastStep, box.previews))
      print("файл: \(file.path)")
    } catch {
      print("ОШИБКА: \(error)")
      exit(1)
    }
  }
}
