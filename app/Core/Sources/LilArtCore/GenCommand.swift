import Foundation

/// What the command line asked `lilart-gen` to do, decided before any engine or file is touched.
/// Every message for a wrong flag is written here, so each can be tested without a GPU.
enum GenCommand: Equatable {
  /// Print the usage and leave; `failed` is the exit code 1 of a bare call with nothing to do.
  case help(failed: Bool)
  /// Rebuild one id's contact sheet. `alone` is false when other flags came with it.
  case sheet(dir: URL, alone: Bool)
  case part(source: URL, checkOnly: Bool)
  case squeeze(input: String, out: String, bits: Int, importantBits: Int, edgeBlocks: Int)
  case generate(GenRun)

  /// Where things are, as the program found them; tests give their own.
  struct Environment {
    var appPort = 0
    var defaultModel = "krea_2_turbo_q8p.ckpt"
    var modelsDir = URL(fileURLWithPath: "/")
    var fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    var readText: (String) -> String? = {
      FileManager.default.contents(atPath: $0).flatMap { String(data: $0, encoding: .utf8) }
    }
  }

  static func parse(_ list: [String], _ env: Environment) throws -> GenCommand {
    let args = try Arguments(list)
    if args.flags.contains("--help") || args.flags.contains("-h") || args.values.isEmpty {
      return .help(failed: args.values.isEmpty && args.flags.isEmpty)
    }
    if let path = args["--sheet"] {
      return .sheet(dir: URL(fileURLWithPath: path).standardizedFileURL, alone: args.values.count == 1)
    }
    if let path = args["--check-part"] ?? args["--import-part"] {
      guard args.values.count == 1 else { throw Fail("--check-part и --import-part ни с чем не сочетаются") }
      return .part(source: URL(fileURLWithPath: path).standardizedFileURL, checkOnly: args["--check-part"] != nil)
    }
    if let path = args["--squeeze"] {
      guard let out = args["--out"] else { throw Fail("для --squeeze нужен --out") }
      let parts = (args["--plan"] ?? "8/8").split(separator: "/").compactMap { Int($0) }
      let bits = parts.first ?? 8
      let important = parts.last ?? 8
      return .squeeze(
        input: path, out: out, bits: bits, importantBits: important, edgeBlocks: bits == important ? 0 : 2)
    }
    return .generate(try GenRun(args, env))
  }
}

/// A picture run: one request, or a batch from a jobs file.
struct GenRun: Equatable {
  struct Lora: Equatable {
    let file: String
    let weight: Float
  }

  /// The picture to change, its mask and the borrowed picture; every field empty = from scratch.
  struct Edit: Equatable {
    var image: String?
    var mask: String?
    var ref: String?
    var strength: Float = 1
    /// White in the mask is drawn from nothing rather than from what is there.
    var fresh = false
  }

  struct Single: Equatable {
    var prompt: String
    var seed: UInt32
    var out: URL
    var count: Int
    var maskBlur: Float?
    var maskOutset: Int?
    var edit: Edit
    var loras: [Lora]
    var upscaler: String?
    var upscaleFactor: Int
  }

  enum Mode: Equatable {
    case batch(jobsPath: String, outDir: String, limit: Int)
    case single(Single)
  }

  var port: Int
  var width: Int
  var height: Int
  var model: String
  var steps: Int?
  var cfg: Float?
  var sampler: String?
  var timeout: Double
  /// The ceiling asked for with --limit; a single run never makes more than its count anyway.
  var limit: Int?
  var negative: String
  var dryRun: Bool
  var mode: Mode

  init(_ args: Arguments, _ env: GenCommand.Environment) throws {
    let validPort = (1...65535).contains(env.appPort) ? env.appPort : 7859
    port = try args.int("--port") ?? validPort
    guard (1...65535).contains(port) else { throw Fail("--port вне 1…65535") }
    width = try checkSize(try args.int("--width") ?? 1024, "--width")
    height = try checkSize(try args.int("--height") ?? 1024, "--height")
    model = args["--model"] ?? env.defaultModel
    if model.hasSuffix(".ckpt"), !env.fileExists(env.modelsDir.appendingPathComponent(model).path) {
      throw Fail("модели \(model) нет в \(env.modelsDir.path)")
    }
    if let v = try args.int("--steps") {
      guard (1...150).contains(v) else { throw Fail("--steps от 1 до 150") }
      steps = v
    }
    if let raw = args["--cfg"] {
      guard let v = Float(raw), v.isFinite, v >= 0, v <= 50 else { throw Fail("--cfg: число от 0 до 50") }
      cfg = v
    }
    sampler = args["--sampler"]
    timeout = 600
    if let raw = args["--timeout"] {
      guard let v = Double(raw), v >= 10 else { throw Fail("--timeout: секунды, не меньше 10") }
      timeout = v
    }
    let limitArg = try args.int("--limit")
    if let limitArg, limitArg < 1 { throw Fail("--limit должен быть от 1") }
    limit = limitArg
    negative = args["--negative"] ?? ""
    dryRun = args.flags.contains("--dry-run")
    mode = try Self.mode(args, env, limit: limitArg, width: width, height: height)
  }

  private static let singleOnly = [
    "--prompt", "--prompt-file", "--out", "--seed", "--image", "--mask", "--ref", "--count", "--strength",
  ]

  private static func mode(
    _ args: Arguments, _ env: GenCommand.Environment, limit: Int?, width: Int, height: Int
  ) throws -> Mode {
    if let jobsPath = args["--jobs"] {
      for flag in singleOnly where args[flag] != nil {
        throw Fail("\(flag) не сочетается с --jobs: промпт, сид и имена файлов берутся из заданий")
      }
      guard let outDir = args["--out-dir"] else { throw Fail("для --jobs нужен --out-dir") }
      guard let limit else { throw Fail("для --jobs нужен --limit N — жёсткий потолок генераций за запуск") }
      return .batch(jobsPath: jobsPath, outDir: outDir, limit: limit)
    }
    guard args["--out-dir"] == nil else { throw Fail("--out-dir только вместе с --jobs; для одной картинки --out") }
    let prompt = try singlePrompt(args, env)
    guard !prompt.isEmpty else { throw Fail("нужен --prompt или --prompt-file (или --jobs)") }
    let seed = try args["--seed"].map(parseSeed) ?? UInt32.random(in: 0...UInt32.max)
    let out = URL(fileURLWithPath: args["--out"] ?? "lilart_\(seed).png").standardizedFileURL
    guard out.pathExtension.lowercased() == "png" else { throw Fail("--out должен кончаться на .png") }
    let count = try args.int("--count") ?? 1
    guard (1...8).contains(count) else { throw Fail("--count от 1 до 8") }
    return .single(
      Single(
        prompt: prompt, seed: seed, out: out, count: count, maskBlur: try maskBlur(args),
        maskOutset: try args.int("--mask-outset"), edit: try edit(args, env),
        loras: try loras(args, env), upscaler: try upscaler(args, env),
        upscaleFactor: try upscaleFactor(args)))
  }

  /// --image / --mask / --ref / --strength / --fresh. A mask or a strength means nothing without
  /// the picture it applies to.
  private static func edit(_ args: Arguments, _ env: GenCommand.Environment) throws -> Edit {
    var edit = Edit(image: args["--image"], mask: args["--mask"], ref: args["--ref"])
    edit.fresh = args.flags.contains("--fresh")
    if let image = edit.image {
      guard env.fileExists(image) else { throw Fail("нет файла \(image)") }
    } else if edit.mask != nil || args["--strength"] != nil {
      throw Fail("--mask и --strength работают только вместе с --image")
    }
    if let ref = edit.ref {
      guard env.fileExists(ref) else { throw Fail("нет файла \(ref)") }
    }
    if let raw = args["--strength"] {
      guard let v = Float(raw), v > 0, v <= 1 else { throw Fail("--strength: число больше 0 и не больше 1") }
      edit.strength = v
    }
    return edit
  }

  private static func singlePrompt(_ args: Arguments, _ env: GenCommand.Environment) throws -> String {
    if let file = args["--prompt-file"] {
      guard args["--prompt"] == nil else { throw Fail("либо --prompt, либо --prompt-file") }
      guard let text = env.readText(file) else { throw Fail("не прочитался \(file)") }
      return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return (args["--prompt"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func maskBlur(_ args: Arguments) throws -> Float? {
    guard let raw = args["--mask-blur"] else { return nil }
    guard let v = Float(raw), (0...64).contains(v) else { throw Fail("--mask-blur: 0…64") }
    return v
  }

  /// "file.ckpt:0.8,other.ckpt:0.5"
  private static func loras(_ args: Arguments, _ env: GenCommand.Environment) throws -> [Lora] {
    guard let list = args["--lora"] else { return [] }
    return try list.split(separator: ",").map { item in
      let parts = item.split(separator: ":", maxSplits: 1).map(String.init)
      let file = parts[0].trimmingCharacters(in: .whitespaces)
      guard env.fileExists(env.modelsDir.appendingPathComponent(file).path) else {
        throw Fail("LoRA \(file) нет в \(env.modelsDir.path)")
      }
      return Lora(file: file, weight: parts.count > 1 ? Float(parts[1]) ?? 1 : 1)
    }
  }

  private static func upscaler(_ args: Arguments, _ env: GenCommand.Environment) throws -> String? {
    guard let up = args["--upscaler"] else { return nil }
    guard env.fileExists(env.modelsDir.appendingPathComponent(up).path) else {
      throw Fail("апскейлера \(up) нет в \(env.modelsDir.path)")
    }
    return up
  }

  private static func upscaleFactor(_ args: Arguments) throws -> Int {
    guard args["--upscaler"] != nil else { return 2 }
    let factor = try args.int("--upscale-factor") ?? 2
    guard [2, 4].contains(factor) else { throw Fail("--upscale-factor: 2 или 4") }
    return factor
  }
}
