import CoreGraphics
import CoreText
import Darwin
import Foundation
import ImageIO
import MediaGenerationKit
import NNC
import UniformTypeIdentifiers

/// Command-line picture generator on top of lil art's engine, for scripts and other tools.
///
/// It never loads a model itself: every picture is asked of the engine that lil art already
/// runs on 127.0.0.1, so the weights sit in memory once. Only when nothing answers there does
/// it start that same engine, the same way the app does, and stop it again on the way out.
/// Full usage: ~/lil-art/tools/GEN.md.
let usage = """
  lilart-gen — картинки через движок lil art, без окна. Подробно: ~/lil-art/tools/GEN.md

  Одна картинка:
    lilart-gen --prompt "текст" --out путь.png [--seed N] [--width 1024 --height 1024]
    lilart-gen --prompt-file промпт.txt --out путь.png

  Правка картинки (одиночный режим):
    lilart-gen --image снимок.png [--mask маска.png] [--strength 0.6] [--ref образец.png] --prompt "…" --out путь.png
    --image                   картинка, которую меняем (подгоняется под --width/--height)
    --mask                    белое — перерисовать, чёрное — оставить; --fresh: белое рисовать с нуля
    --strength 0…1            насколько перерисовывать (1 — для моделей, что правят по описанию)
    --ref                     картинка-образец (moodboard)
    --count N                 N вариантов (сиды seed, seed+1, …) → путь_1.png, путь_2.png, …
    --lora файл:вес,...       LoRA из папки моделей (вес 0…2, по умолчанию 1)
    --mask-blur X             мягкий край маски (0…64), --mask-outset N — расширить её на N пикселей
    --upscaler файл.ckpt      сразу увеличить результат (4x_ultrasharp_f16.ckpt), --upscale-factor 2|4

  Пачка:
    lilart-gen --jobs jobs.json --out-dir папка --limit N [--dry-run]
    jobs.json: [{"id": "hero", "prompt": "...", "count": 4, "seed": 1, "width": 1024, "height": 1024}]

  Флаги:
    --model файл.ckpt         модель (по умолчанию krea_2_turbo_q8p.ckpt)
    --width, --height         кратны 64, по умолчанию 1024
    --steps N, --cfg X        поверх рекомендации модели
    --sampler имя             например "DDIM Trailing", "Euler A Trailing"
    --negative текст          Negative prompt (при CFG 1 не действует)
    --seed N                  без него случайный; всегда печатается
    --limit N                 жёсткий потолок генераций за запуск (для --jobs обязателен)
    --timeout сек             сколько ждать одну картинку (по умолчанию 600)
    --port N                  порт движка (по умолчанию как в lil art, обычно 7859)
    --dry-run                 показать план и настройки, ничего не генерировать

  Лист заново (без генерации), например после удаления неудачных вариантов:
    lilart-gen --sheet папка/<id>

  Свой VAE или кодировщик (дообученная копия стандартной части установленной модели), без генерации:
    lilart-gen --check-part файл.safetensors     только сверить слои, ничего не записывая
    lilart-gen --import-part файл.safetensors    сверить и положить в папку моделей
  Выбирается потом в lil art: PRO у модели → «VAE» / «текстовый кодировщик».

  Сжать модель движка в отдельный файл и сверить каждый слой с оригиналом:
    lilart-gen --squeeze модель.ckpt --plan 4/8 --out копия.ckpt
    --plan основная/важные биты (8, 6, 5, 4, 3); в папку моделей ничего не пишется.

  Вывод (stdout, через табуляцию, по строке на картинку):
    OK    <id> <n> <seed> <секунды> <путь>
    FAIL  <id> <n> <seed> <секунды> <причина>
    SHEET <id> <сколько вариантов> <путь>
    DONE  ok=<..> failed=<..> attempts=<..> limit=<..>
  Всё остальное — в stderr.
  """

let defaultModel = "krea_2_turbo_q8p.ckpt"
let home = FileManager.default.homeDirectoryForCurrentUser
let modelsDir = ModelsFolder.url
let engineBinary = home.appendingPathComponent("lil-art/engine/gRPCServerCLI-macOS")
let engineLog = home.appendingPathComponent("lil-art/engine.log")
/// lil art's own settings, so a started engine gets the same port and weights cache.
let appDefaults = UserDefaults(suiteName: "com.lil.art")

func say(_ text: String) {
  FileHandle.standardError.write(Data((text + "\n").utf8))
}

/// One line on stdout per result; tabs, so a caller can split it without guessing.
func emit(_ fields: [String]) {
  print(fields.map { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
    .joined(separator: "\t"))
}

// MARK: - arguments

/// Takes the engine's own name ("DDIM Trailing", "DPM++ 2M Karras") or the code one
/// (dDIMTrailing, dPMPP2MKarras): case, spaces and punctuation do not matter.
func parseSampler(_ raw: String) throws -> SamplerType {
  if let n = Int8(raw), let s = SamplerType(rawValue: n) { return s }
  func plain(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
  if let s = SamplerType.allCases.first(where: { plain("\($0)") == plain(raw) }) { return s }
  throw Fail("--sampler «\(raw)» неизвестен. Есть: " + SamplerType.allCases.map { "\($0)" }.joined(separator: ", "))
}

// MARK: - engine process

/// The engine the pictures are asked of. It is used as found when it answers; started only
/// when nothing does, and then — and only then — stopped at the end.
final class Engine: @unchecked Sendable {
  let port: Int
  private let lock = NSLock()
  private var started: Process?
  private var starts = 0

  init(port: Int) { self.port = port }

  var startedByUs: Bool {
    lock.lock()
    defer { lock.unlock() }
    return started?.isRunning == true
  }

  /// lil art's "keep the model in memory" setting, passed on exactly as the app does.
  static var weightsCacheGB: Int {
    Int((appDefaults?.double(forKey: "engine.cacheGB") ?? 0).rounded())
  }

  func answering() -> Bool { knock(port: port) }

  /// Returns once something answers on the port, starting the engine if nobody runs it.
  func ensure() throws {
    if answering() { return }
    if let mine = ownProcess, mine.isRunning {
      // ours is alive but silent: give it time rather than start a second copy next to it
      say("движок, запущенный мной, не отвечает — жду")
      if waitReady(seconds: 120, watching: mine) { return }
      stopIfOurs()
      throw Fail("движок перестал отвечать, см. ~/lil-art/engine.log")
    }
    let others = Engine.pids(running: engineBinary.path).subtracting(ownProcess.map { [$0.processIdentifier] } ?? [])
    if !others.isEmpty {
      // Somebody (lil art, most likely) is starting it right now. A second copy would load
      // the model a second time, which this machine does not have the memory for.
      say("движок уже запущен (pid \(others.sorted().map(String.init).joined(separator: ", "))), жду, пока он ответит на порту \(port)")
      if waitReady(seconds: 120, watching: nil) { return }
      throw Fail(
        "движок запущен, но порт \(port) не отвечает 2 минуты. Второй копией не запускаю, чтобы не грузить модель дважды. "
          + "Проверьте lil art или ~/lil-art/engine.log")
    }
    guard FileManager.default.isExecutableFile(atPath: engineBinary.path) else {
      throw Fail("движка нет: \(engineBinary.path). Его скачивает lil art при первом запуске")
    }
    lock.lock()
    let attempt = starts
    starts += 1
    lock.unlock()
    guard attempt < 3 else { throw Fail("движок уже трижды поднимался и падал — останавливаюсь, см. ~/lil-art/engine.log") }
    let p = try launch()
    say("запустил движок сам (pid \(p.processIdentifier)), порт \(port); остановлю его в конце")
    guard waitReady(seconds: 120, watching: p) else {
      stopIfOurs()
      throw Fail("движок не ответил за 2 минуты, см. ~/lil-art/engine.log")
    }
    say("движок готов")
  }

  private var ownProcess: Process? {
    lock.lock()
    defer { lock.unlock() }
    return started
  }

  private func launch() throws -> Process {
    let p = Process()
    p.executableURL = engineBinary
    // Without --address the engine listens on every network interface, i.e. the whole Wi-Fi.
    var arguments = [modelsDir.path, "--address", "127.0.0.1", "--port", String(port)]
    let cache = Engine.weightsCacheGB
    if cache > 0 { arguments += ["--weights-cache", String(cache)] }
    p.arguments = arguments
    p.standardInput = FileHandle.nullDevice
    let fd = open(engineLog.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    if fd >= 0 {
      let log = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
      let stamp = ISO8601DateFormatter().string(from: Date())
      try? log.write(contentsOf: Data("\n--- запуск из lilart-gen \(stamp) ---\n".utf8))
      p.standardOutput = log
      p.standardError = log
    }
    try p.run()
    lock.lock()
    started = p
    lock.unlock()
    return p
  }

  private func waitReady(seconds: Double, watching p: Process?) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      if answering() { return true }
      if let p, !p.isRunning {
        say("движок завершился сам (код \(p.terminationStatus)), см. ~/lil-art/engine.log")
        return false
      }
      usleep(500_000)
    }
    return false
  }

  /// Polite first, then SIGKILL — the memory only comes back once the process is gone.
  func stopIfOurs() {
    lock.lock()
    let p = started
    started = nil
    lock.unlock()
    guard let p, p.isRunning else { return }
    say("останавливаю движок, который запускал сам (pid \(p.processIdentifier))")
    p.terminate()
    for _ in 0..<50 where p.isRunning { usleep(100_000) }
    if p.isRunning { kill(p.processIdentifier, SIGKILL) }
  }

  /// Process ids whose executable is exactly `path` (same check lil art uses).
  static func pids(running path: String) -> Set<pid_t> {
    let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    let size = Int32(MemoryLayout<pid_t>.size)
    let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
    guard needed > 0 else { return [] }
    var list = [pid_t](repeating: 0, count: Int(needed / size) + 64)
    let filled = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &list, Int32(list.count) * size)
    guard filled > 0 else { return [] }
    var buffer = [UInt8](repeating: 0, count: 4096)
    var found: Set<pid_t> = []
    for pid in list.prefix(Int(filled / size)) where pid > 0 {
      let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
      guard length > 0 else { continue }
      let running = String(decoding: buffer[0..<Int(length)], as: UTF8.self)
      if running == path || running == resolved { found.insert(pid) }
    }
    return found
  }
}

/// A plain TCP knock on 127.0.0.1: the port is open once the server listens.
func knock(port: Int) -> Bool {
  guard let p = UInt16(exactly: port) else { return false }
  let fd = socket(AF_INET, SOCK_STREAM, 0)
  guard fd >= 0 else { return false }
  defer { close(fd) }
  _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
  var address = sockaddr_in()
  address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
  address.sin_family = sa_family_t(AF_INET)
  address.sin_port = p.bigEndian
  address.sin_addr.s_addr = inet_addr("127.0.0.1")
  let result = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
  }
  if result == 0 { return true }
  guard errno == EINPROGRESS else { return false }
  var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
  guard poll(&poller, 1, 1000) == 1 else { return false }
  var error: Int32 = 0
  var length = socklen_t(MemoryLayout<Int32>.size)
  getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
  return error == 0
}

// MARK: - generation

struct Settings {
  var steps: Int
  var cfg: Float
  var sampler: SamplerType
}

/// Lets exactly one of two racing outcomes through.
final class Once: @unchecked Sendable {
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

/// The answer comes back when time is up even if the work ignores cancellation.
func withTimeout<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async throws -> T)
  async throws -> T
{
  let once = Once()
  return try await withCheckedThrowingContinuation { (done: CheckedContinuation<T, Error>) in
    let worker = Task {
      do {
        let value = try await work()
        if once.claim() { done.resume(returning: value) }
      } catch {
        if once.claim() { done.resume(throwing: error) }
      }
    }
    Task {
      try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
      if once.claim() {
        worker.cancel()
        done.resume(throwing: Fail("не уложилась в \(Int(seconds)) с, отменена"))
      }
    }
  }
}

/// The picture to change, its mask and the borrowed picture → the engine's inputs. The mask is
/// any picture where white (or light) means "redraw" and black "keep"; it is rewritten at the
/// output size in the engine's own levels (0 keep, 2 redraw from what is there, 1 from scratch).
func editInputs(_ edit: GenRun.Edit, width: Int, height: Int) throws -> [MediaGenerationPipeline.Input] {
  var inputs: [MediaGenerationPipeline.Input] = []
  if let image = edit.image { inputs.append(MediaGenerationPipeline.file(image)) }
  if let mask = edit.mask {
    inputs.append(
      MediaGenerationPipeline.file(try engineMask(mask, width: width, height: height, fresh: edit.fresh).path).mask())
  }
  if let ref = edit.ref { inputs.append(MediaGenerationPipeline.file(ref).moodboard()) }
  return inputs
}

func engineMask(_ path: String, width: Int, height: Int, fresh: Bool) throws -> URL {
  guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
    let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
  else { throw Fail("маска не прочиталась: \(path)") }
  var grey = [UInt8](repeating: 0, count: width * height)
  guard let ctx = CGContext(data: &grey, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
  else { throw Fail("маска не перерисовалась") }
  ctx.interpolationQuality = .high
  ctx.draw(img, in: CGRect(x: 0, y: 0, width: width, height: height))
  guard grey.contains(where: { $0 >= 128 }) else { throw Fail("в маске ничего не закрашено (белое — перерисовать)") }
  let redraw: UInt8 = fresh ? 1 : 2
  var rgb = [UInt8](repeating: 0, count: width * height * 3)
  for i in 0..<(width * height) where grey[i] >= 128 {
    rgb[i * 3] = redraw; rgb[i * 3 + 1] = redraw; rgb[i * 3 + 2] = redraw
  }
  guard let provider = CGDataProvider(data: Data(rgb) as CFData),
    let out = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: width * 3,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
  else { throw Fail("маска не собралась") }
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("lilart-gen-mask-\(UUID().uuidString).png")
  try savePNG(out, to: url)
  return url
}

/// One picture, as PNG bytes. The preview is never read: decoding it is what used to take
/// the process down for some model families, and nobody watches it here anyway.
func render(
  _ pipeline: MediaGenerationPipeline, base: MediaGenerationPipeline.Configuration,
  settings: Settings, prompt: String, negative: String, seed: UInt32, width: Int, height: Int,
  timeout: Double, inputs: [MediaGenerationPipeline.Input] = [], strength: Float = 1,
  upscaler: String? = nil, upscaleFactor: Int = 0, maskBlur: Float? = nil, maskOutset: Int? = nil, masked: Bool = false, loras: [LoRA] = []
) async throws -> Data {
  var p = pipeline
  p.configuration = base
  p.configuration.width = width
  p.configuration.height = height
  p.configuration.seed = seed
  p.configuration.steps = settings.steps
  p.configuration.guidanceScale = settings.cfg
  p.configuration.sampler = settings.sampler
  p.configuration.batchCount = 1
  p.configuration.batchSize = 1
  // with a starting picture, strength is how much of it is redrawn (1 = all, as for models
  // that edit by instruction); without one there is nothing to keep
  p.configuration.strength = inputs.isEmpty ? 1 : strength
  p.configuration.upscaler = upscaler
  p.configuration.upscalerScaleFactor = upscaler == nil ? 0 : upscaleFactor
  // soft edge of the redrawn part (the engine's answer to ComfyUI's differential diffusion);
  // outside the mask the original comes back pixel for pixel
  if let maskBlur { p.configuration.maskBlur = maskBlur }
  if let maskOutset { p.configuration.maskBlurOutset = maskOutset }
  if masked { p.configuration.preserveOriginalAfterInpaint = true }
  if !loras.isEmpty {
    // the model's own LoRAs stay unless the same file is asked for with another weight
    let asked = Set(loras.compactMap(\.file))
    p.configuration.loras = base.loras.filter { !asked.contains($0.file ?? "") } + loras
  }
  let job = p
  let results = try await withTimeout(timeout) {
    // "STEP i/n" on stderr, so a caller can show progress (the preview is never read)
    try await job.generate(prompt: prompt, negativePrompt: negative, inputs: inputs) { state, _ in
      if case let .generating(step, total) = state { say("STEP \(step)/\(total)") }
    }
  }
  guard let first = results.first else { throw Fail("движок вернул пустой результат") }
  // Some decoders send four channels (alpha first); TensorImage reads both layouts.
  if let encoded = TensorImage.png(first.tensor) { return encoded.png }
  let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("lilart-gen-\(UUID()).png")
  defer { try? FileManager.default.removeItem(at: scratch) }
  try first.write(to: scratch, type: .png)
  return try Data(contentsOf: scratch)
}

// MARK: - contact sheet

/// All variants of one id on a single 1024×1024 picture, each numbered in its corner, so a
/// reviewer opens one file instead of four.
enum Sheet {
  static let side = 1024

  static func write(_ files: [(n: Int, url: URL)], to destination: URL) throws {
    guard !files.isEmpty else { return }
    let gap = 6
    let columns = Int(Double(files.count).squareRoot().rounded(.up))
    let rows = (files.count + columns - 1) / columns
    let cellW = (side - gap * (columns + 1)) / columns
    let cellH = (side - gap * (rows + 1)) / rows
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let ctx = CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { throw Fail("не создался холст для листа") }
    ctx.setFillColor(CGColor(srgbRed: 0.08, green: 0.08, blue: 0.08, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
    ctx.interpolationQuality = .high
    for (index, file) in files.enumerated() {
      let column = index % columns
      let row = index / columns
      // CoreGraphics counts y from the bottom; rows are laid out from the top.
      let cell = CGRect(
        x: gap + column * (cellW + gap), y: side - (gap + row * (cellH + gap)) - cellH,
        width: cellW, height: cellH)
      guard let image = thumbnail(file.url, maxPixel: max(cellW, cellH)) else { continue }
      let scale = min(cell.width / CGFloat(image.width), cell.height / CGFloat(image.height))
      let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
      let frame = CGRect(
        x: cell.midX - size.width / 2, y: cell.midY - size.height / 2, width: size.width,
        height: size.height
      ).integral
      ctx.draw(image, in: frame)
      label(String(file.n), in: ctx, topLeft: CGPoint(x: frame.minX, y: frame.maxY),
            fontSize: max(14, CGFloat(min(cellW, cellH)) * 0.075))
    }
    guard let image = ctx.makeImage() else { throw Fail("лист не собрался") }
    try savePNG(image, to: destination)
  }

  private static func thumbnail(_ url: URL, maxPixel: Int) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixel,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }

  private static func label(_ text: String, in ctx: CGContext, topLeft: CGPoint, fontSize: CGFloat) {
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
    let attributes: [NSAttributedString.Key: Any] = [
      NSAttributedString.Key(kCTFontAttributeName as String): font,
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    var ascent: CGFloat = 0
    var descent: CGFloat = 0
    let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
    let pad = fontSize * 0.35
    let inset = fontSize * 0.3
    let box = CGRect(
      x: topLeft.x + inset, y: topLeft.y - inset - (ascent + descent + pad * 2),
      width: width + pad * 2, height: ascent + descent + pad * 2)
    ctx.setFillColor(CGColor(gray: 0, alpha: 0.72))
    ctx.addPath(CGPath(roundedRect: box, cornerWidth: pad, cornerHeight: pad, transform: nil))
    ctx.fillPath()
    ctx.textMatrix = .identity
    ctx.textPosition = CGPoint(x: box.minX + pad, y: box.minY + pad + descent)
    CTLineDraw(line, ctx)
  }
}

func savePNG(_ image: CGImage, to url: URL) throws {
  guard let output = CFDataCreateMutable(nil, 0),
    let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
  else { throw Fail("PNG не создался") }
  CGImageDestinationAddImage(destination, image, nil)
  guard CGImageDestinationFinalize(destination) else { throw Fail("PNG не записался") }
  try (output as Data).write(to: url, options: .atomic)
}

// MARK: - run

/// One picture to make: where it goes and with what.
struct Shot {
  let id: String
  let n: Int
  let seed: UInt32
  let prompt: String
  let width: Int
  let height: Int
  let destination: URL
}

/// Owns the budget. `attempts` is raised before a request is sent, and nothing is sent once
/// it reaches the limit — a request that fails half-way has still used the GPU.
final class Runner {
  let engine: Engine
  let model: String
  let negative: String
  let overrides: (steps: Int?, cfg: Float?, sampler: SamplerType?)
  let limit: Int
  let timeout: Double
  /// Picture to change, its mask and borrowed pictures (single mode only); empty = from scratch.
  var inputs: [MediaGenerationPipeline.Input] = []
  var strength: Float = 1
  /// The engine's upscaler, run right after the picture in the same request.
  var upscaler: String?
  var upscaleFactor = 2
  var maskBlur: Float?
  var maskOutset: Int?
  var masked = false
  var loras: [LoRA] = []
  private var pipeline: MediaGenerationPipeline?
  private var base: MediaGenerationPipeline.Configuration?
  private(set) var settings: Settings?
  private(set) var attempts = 0
  private(set) var ok = 0
  private(set) var failed = 0
  private var failedInARow = 0
  /// Set when going on would only burn the budget on the same failure.
  private(set) var stopped: String?

  init(engine: Engine, model: String, negative: String,
       overrides: (steps: Int?, cfg: Float?, sampler: SamplerType?), limit: Int, timeout: Double)
  {
    self.engine = engine
    self.model = model
    self.negative = negative
    self.overrides = overrides
    self.limit = limit
    self.timeout = timeout
  }

  var budgetLeft: Bool { attempts < limit && stopped == nil }

  /// Opens the model on the engine and settles steps, CFG and sampler: the model's own
  /// recommendation first, then whatever was asked for on the command line.
  func prepare() async throws {
    MediaGenerationEnvironment.default.externalUrls = [modelsDir]
    let backend = MediaGenerationPipeline.Backend.remote(.init(host: "127.0.0.1", port: engine.port))
    let fresh = try await MediaGenerationPipeline.fromPretrained(model, backend: backend)
    let recommended = fresh.configuration
    var s = Settings(steps: recommended.steps, cfg: recommended.guidanceScale, sampler: recommended.sampler)
    if settings == nil {
      say("рекомендация модели: \(s.steps) шагов, CFG \(s.cfg), сэмплер \(s.sampler)")
    }
    if let v = overrides.steps { s.steps = v }
    if let v = overrides.cfg { s.cfg = v }
    if let v = overrides.sampler { s.sampler = v }
    if settings == nil {
      say("будет: \(s.steps) шагов, CFG \(s.cfg), сэмплер \(s.sampler), модель \(model)")
    }
    pipeline = fresh
    base = recommended
    settings = s
  }

  /// Makes one picture if the budget allows. Returns whether a file was written.
  @discardableResult
  func shoot(_ shot: Shot) async -> Bool {
    guard budgetLeft else { return false }
    do {
      try engine.ensure()
      if pipeline == nil { try await prepare() }
    } catch {
      // Nothing was sent, so nothing was spent; but without an engine there is no going on.
      stopped = "не удалось подготовить движок или модель: \(error)"
      emit(["FAIL", shot.id, String(shot.n), String(shot.seed), "0.0", stopped!])
      return false
    }
    guard let pipeline, let base, let settings else { return false }
    attempts += 1
    say("SHOT \(shot.n)")   // for a caller's progress: which picture the STEP lines belong to
    let t0 = Date()
    do {
      let png = try await render(
        pipeline, base: base, settings: settings, prompt: shot.prompt, negative: negative,
        seed: shot.seed, width: shot.width, height: shot.height, timeout: timeout,
        inputs: inputs, strength: strength, upscaler: upscaler, upscaleFactor: upscaleFactor,
        maskBlur: maskBlur, maskOutset: maskOutset, masked: masked, loras: loras)
      try FileManager.default.createDirectory(
        at: shot.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      try png.write(to: shot.destination, options: .atomic)
      ok += 1
      failedInARow = 0
      emit(["OK", shot.id, String(shot.n), String(shot.seed),
            String(format: "%.1f", Date().timeIntervalSince(t0)), shot.destination.path])
      return true
    } catch {
      failed += 1
      failedInARow += 1
      emit(["FAIL", shot.id, String(shot.n), String(shot.seed),
            String(format: "%.1f", Date().timeIntervalSince(t0)), String(describing: error)])
      // the connection may be what broke; open the model afresh for the next one
      self.pipeline = nil
      if failedInARow >= 3 {
        stopped = "три ошибки подряд — похоже, сломалось что-то общее, дальше не трачу лимит"
      }
      return false
    }
  }
}

@main
struct LilArtGen {
  static func main() async {
    // Line by line even into a file, so a caller watching the output sees each picture land.
    setvbuf(stdout, nil, _IOLBF, 0)
    var environment = GenCommand.Environment()
    environment.appPort = appDefaults?.integer(forKey: "engine.port") ?? 0
    environment.defaultModel = defaultModel
    environment.modelsDir = modelsDir
    let command: GenCommand
    do { command = try GenCommand.parse(Array(CommandLine.arguments.dropFirst()), environment) } catch {
      fail(error)
    }
    switch command {
    case .help(let failed):
      say(usage)
      exit(failed ? 1 : 0)
    case .sheet(let dir, let alone):
      rebuildSheet(dir, alone: alone)
    case .part(let source, let checkOnly):
      runPart(source, checkOnly: checkOnly)
    case .squeeze(let input, let out, let bits, let important, let edge):
      runSqueeze(
        input: input, out: out,
        plan: CompressionPlan(bits: bits, importantBits: important, edgeBlocks: edge))
    case .generate(let run):
      await generate(run)
    }
  }

  static func fail(_ error: Error) -> Never {
    say("ошибка: \(error)")
    exit(1)
  }

  // MARK: contact sheet

  /// Rebuilds one id's contact sheet from whatever variants are in its folder now.
  static func rebuildSheet(_ dir: URL, alone: Bool) -> Never {
    let id = dir.lastPathComponent
    let files = variants(of: id, in: dir)
    guard alone, !files.isEmpty else {
      say(files.isEmpty ? "ошибка: в \(dir.path) нет файлов \(id)_<n>_<seed>.png" : "ошибка: --sheet ни с чем не сочетается")
      exit(1)
    }
    let sheet = dir.appendingPathComponent("\(id)_sheet.png")
    do { try Sheet.write(files, to: sheet) } catch { fail(error) }
    emit(["SHEET", id, String(files.count), sheet.path])
    exit(0)
  }

  /// Prints a percentage each time it crosses a multiple of `every`.
  static func progressPrinter(every: Int) -> (Double) -> Void {
    var shown = -1
    return { fraction in
      let percent = Int(fraction * 100)
      if percent / every != shown / every {
        shown = percent
        say("  \(percent)%")
      }
    }
  }

  // MARK: parts (VAE, text encoder)

  /// The same pairing and conversion the models window runs on a dropped file; no engine.
  static func runPart(_ source: URL, checkOnly: Bool) -> Never {
    let catalog = home.appendingPathComponent("lil-art/cache/models.json")
    let started = Date()
    let progress = progressPrinter(every: 5)
    do {
      if checkOnly {
        let checks = try ModelParts.check(source, in: modelsDir, catalog: catalog, progress: progress)
        if checks.isEmpty { say("ни одна установленная стандартная часть не подходит по размерам слоёв") }
        for c in checks {
          let ways = c.transforms.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
          emit([
            c.matched == c.total ? "MATCH" : "PARTIAL", c.stock, c.slot.rawValue, "\(c.matched)/\(c.total)",
            String(format: "min=%.4f mean=%.5f", c.weakest, c.mean), ways,
          ])
        }
      } else {
        let outcome = try ModelParts.install(source, in: modelsDir, catalog: catalog, progress: progress)
        emit([
          "PART", outcome.file, outcome.entry.slot.rawValue, outcome.entry.stock,
          String(format: "%.0f", Date().timeIntervalSince(started)),
          "also=" + (outcome.entry.alsoFits ?? []).joined(separator: ","),
        ])
      }
    } catch { fail(error) }
    exit(0)
  }

  // MARK: squeezing a model

  /// The family decides what stays at 16 bits; custom.json or the catalog knows it.
  static func familyOfModel(named file: String) -> String {
    for url in [modelsDir.appendingPathComponent("custom.json"), home.appendingPathComponent("lil-art/cache/models.json")] {
      guard let data = try? Data(contentsOf: url), let raw = try? JSONSerialization.jsonObject(with: data)
      else { continue }
      let items = (raw as? [[String: Any]]) ?? ((raw as? [String: Any])?["models"] as? [[String: Any]]) ?? []
      if let family = items.first(where: { ($0["file"] as? String) == file })?["version"] as? String,
        !family.isEmpty
      {
        return family
      }
    }
    return ""
  }

  static func runSqueeze(input name: String, out outPath: String, plan: CompressionPlan) -> Never {
    let input = URL(fileURLWithPath: name, relativeTo: modelsDir).standardizedFileURL.path
    let family = familyOfModel(named: URL(fileURLWithPath: input).lastPathComponent)
    guard WeightCompressor.canCompress(family) else {
      say("ошибка: семейство «\(family)» сжимать не умею")
      exit(1)
    }
    let estimate = WeightCompressor.estimate(input: input, version: family, plan: plan) ?? 0
    say(String(format: "семейство %@, план %@, оценка %.2f ГБ", family, plan.label, Double(estimate) / 1_073_741_824))
    let started = Date()
    do {
      try WeightCompressor.compress(
        input: input, output: outPath, version: family, plan: plan, progress: progressPrinter(every: 10))
    } catch { fail(error) }
    let size = (try? FileManager.default.attributesOfItem(atPath: outPath)[.size] as? Int64) ?? 0
    say(String(format: "записано %.2f ГБ за %.0f с; сверяю слои", Double(size) / 1_073_741_824, Date().timeIntervalSince(started)))
    let report = compareLayers(original: input, copy: outPath)
    emit([
      "SQUEEZE", outPath, String(format: "%.2fGB", Double(size) / 1_073_741_824),
      String(format: "mean_err=%.4f", report.counted > 0 ? report.sum / Double(report.counted) : 0),
      String(format: "worst_err=%.4f", report.worst), report.worstKey,
    ])
    exit(0)
  }

  /// Every tensor read back and compared with the original: relative error of the numbers.
  static func compareLayers(original input: String, copy outPath: String)
    -> (worst: Double, sum: Double, counted: Int, worstKey: String)
  {
    var report = (worst: 0.0, sum: 0.0, counted: 0, worstKey: "")
    let graph = DynamicGraph()
    let codecs: DynamicGraph.Store.Codec = [.q8p, .q6p, .q5p, .q4p, .i8x, .ezm7, .externalData]
    graph.openStore(input, flags: .readOnly) { original in
      graph.openStore(outPath, flags: .readOnly) { copy in
        for key in original.keys {
          // the packed k formats unpack only on the GPU, the way the engine reads them
          guard let a = original.read(key, codec: codecs),
            let b = copy.read(key, kind: .GPU(0), codec: codecs)
          else {
            say("  нет слоя \(key)")
            continue
          }
          guard let rel = relativeError(Tensor<Float>(from: a), b) else { continue }
          report.sum += rel
          report.counted += 1
          if rel > report.worst {
            report.worst = rel
            report.worstKey = key
          }
        }
      }
    }
    return report
  }

  /// √(Σ(x − y)² / Σx²) of two tensors of the same size; nil when they differ in size or hold one number.
  static func relativeError(_ x: Tensor<Float>, _ b: AnyTensor) -> Double? {
    let y: Tensor<Float>
    switch b.dataType {
    case .Float32: y = Tensor<Float>(b).toCPU()
    default: y = Tensor<Float>(from: Tensor<Float16>(b).toCPU())
    }
    let n = x.shape.reduce(1, *)
    guard n == y.shape.reduce(1, *), n > 1 else { return nil }
    var err = 0.0
    var mag = 0.0
    x.withUnsafeBytes { xr in
      y.withUnsafeBytes { yr in
        let xp = xr.bindMemory(to: Float.self)
        let yp = yr.bindMemory(to: Float.self)
        for i in 0..<n {
          let d = Double(xp[i] - yp[i])
          err += d * d
          mag += Double(xp[i]) * Double(xp[i])
        }
      }
    }
    return mag > 0 ? (err / mag).squareRoot() : 0
  }

  // MARK: pictures

  /// What a run needs after the command line is read: the engine, the runner with its budget, and
  /// either one request (with its extra variants) or the jobs of a batch.
  struct Prepared {
    let engine: Engine
    let runner: Runner
    var jobs: [Job]?
    var single: Shot?
    var extra: [Shot] = []
  }

  static func generate(_ run: GenRun) async {
    let prepared: Prepared
    do { prepared = try prepare(run) } catch { fail(error) }
    let engine = prepared.engine
    let runner = prepared.runner

    // Ctrl-C or a kill from a caller: an engine this run started must not stay behind holding
    // 18 GB. (SIGKILL cannot be caught; lil art clears such a leftover when it next starts.)
    var watchers: [DispatchSourceSignal] = []
    for sig in [SIGINT, SIGTERM, SIGHUP] {
      signal(sig, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
      source.setEventHandler {
        say("прервано")
        engine.stopIfOurs()
        exit(130)
      }
      source.resume()
      watchers.append(source)
    }
    defer { withExtendedLifetime(watchers) {} }

    if let single = prepared.single {
      await runSingle(single, extra: prepared.extra, runner: runner, engine: engine, dryRun: run.dryRun)
    }
    guard let jobs = prepared.jobs, case .batch(_, let outDir, _) = run.mode else { return }
    await runBatch(jobs, outDir: URL(fileURLWithPath: outDir).standardizedFileURL, runner: runner, engine: engine, dryRun: run.dryRun)
  }

  static func prepare(_ run: GenRun) throws -> Prepared {
    let sampler = try run.sampler.map(parseSampler)
    let engine = Engine(port: run.port)
    let overrides = (steps: run.steps, cfg: run.cfg, sampler: sampler)
    switch run.mode {
    case .batch(let jobsPath, _, let limit):
      let jobs = try loadJobs(jobsPath, width: run.width, height: run.height, warn: say)
      let runner = Runner(engine: engine, model: run.model, negative: run.negative,
                          overrides: overrides, limit: limit, timeout: run.timeout)
      return Prepared(engine: engine, runner: runner, jobs: jobs)
    case .single(let s):
      // several variants of one request: seed, seed+1, … into out_1.png, out_2.png, …
      let stem = s.out.deletingPathExtension().path
      func shot(_ i: Int) -> Shot {
        Shot(id: "single", n: i + 1, seed: s.seed &+ UInt32(i), prompt: s.prompt, width: run.width,
             height: run.height,
             destination: i == 0 && s.count == 1 ? s.out : URL(fileURLWithPath: stem + "_\(i + 1).png"))
      }
      let runner = Runner(engine: engine, model: run.model, negative: run.negative,
                          overrides: overrides, limit: min(run.limit ?? s.count, s.count), timeout: run.timeout)
      runner.inputs = try editInputs(s.edit, width: run.width, height: run.height)
      runner.strength = s.edit.strength
      runner.maskBlur = s.maskBlur
      runner.maskOutset = s.maskOutset
      runner.masked = s.edit.mask != nil
      runner.loras = s.loras.map { LoRA(file: $0.file, weight: $0.weight) }
      if let up = s.upscaler {
        runner.upscaler = up
        runner.upscaleFactor = s.upscaleFactor
      }
      return Prepared(engine: engine, runner: runner, single: shot(0), extra: (1..<s.count).map(shot))
    }
  }

  static func runSingle(_ single: Shot, extra: [Shot], runner: Runner, engine: Engine, dryRun: Bool) async -> Never {
    say("сид: \(single.seed)")
    if dryRun {
      say("--dry-run: была бы 1 картинка \(single.width)×\(single.height) → \(single.destination.path)")
      await showSettings(runner, engine: engine)
      exit(0)
    }
    await runner.shoot(single)
    for shot in extra where runner.budgetLeft { await runner.shoot(shot) }
    finish(runner, engine: engine)
  }

  /// How many pictures each job gets of the ceiling, in the order of the file.
  static func allocate(_ jobs: [Job], limit: Int) -> [(Job, Int)] {
    var left = limit
    return jobs.map { job in
      let take = min(job.count, left)
      left -= take
      return (job, take)
    }
  }

  static func runBatch(_ jobs: [Job], outDir: URL, runner: Runner, engine: Engine, dryRun: Bool) async {
    let requested = jobs.reduce(0) { $0 + $1.count }
    let plan = allocate(jobs, limit: runner.limit)
    say("план: \(min(requested, runner.limit)) из \(requested) запрошенных, лимит \(runner.limit), папка \(outDir.path)")
    for (job, take) in plan {
      say("  \(job.id): \(take) из \(job.count), \(job.width)×\(job.height)" + (job.seed.map { ", сиды с \($0)" } ?? ", сиды случайные"))
    }
    if requested > runner.limit {
      let cut = plan.filter { $0.1 < $0.0.count }.map { "\($0.0.id) (\($0.1)/\($0.0.count))" }
      say("лимит меньше запрошенного: урезаны \(cut.joined(separator: ", "))")
    }
    if dryRun {
      await showSettings(runner, engine: engine)
      exit(0)
    }
    for (job, take) in plan where take > 0 {
      guard runner.budgetLeft else { break }
      await shootJob(job, take: take, in: outDir.appendingPathComponent(job.id), runner: runner)
    }
    finish(runner, engine: engine)
  }

  /// One job's pictures, numbered on from what its folder already holds, then its sheet.
  static func shootJob(_ job: Job, take: Int, in dir: URL, runner: Runner) async {
    var n = (variants(of: job.id, in: dir).last?.n ?? 0) + 1
    var made = 0
    for k in 0..<take {
      guard runner.budgetLeft else { break }
      let seed = job.seed.map { $0 &+ UInt32(truncatingIfNeeded: k) } ?? UInt32.random(in: 0...UInt32.max)
      let file = dir.appendingPathComponent("\(job.id)_\(n)_\(seed).png")
      if await runner.shoot(Shot(id: job.id, n: n, seed: seed, prompt: job.prompt, width: job.width,
                                 height: job.height, destination: file))
      {
        made += 1
      }
      n += 1
    }
    let all = variants(of: job.id, in: dir)
    guard made > 0, !all.isEmpty else { return }
    let sheet = dir.appendingPathComponent("\(job.id)_sheet.png")
    do {
      try Sheet.write(all, to: sheet)
      emit(["SHEET", job.id, String(all.count), sheet.path])
    } catch {
      say("\(job.id): лист не собрался: \(error)")
    }
  }

  /// What the run would use, without spending a generation. Asks only the model's settings.
  static func showSettings(_ runner: Runner, engine: Engine) async {
    say("движок на 127.0.0.1:\(engine.port): " + (engine.answering() ? "отвечает" : "не отвечает — будет запущен с --weights-cache \(Engine.weightsCacheGB)"))
    do { try await runner.prepare() } catch { say("настройки модели не получены: \(error)") }
  }

  static func finish(_ runner: Runner, engine: Engine) -> Never {
    if let reason = runner.stopped { say("остановлено: \(reason)") }
    engine.stopIfOurs()
    emit(["DONE", "ok=\(runner.ok)", "failed=\(runner.failed)", "attempts=\(runner.attempts)",
          "limit=\(runner.limit)"])
    exit(runner.failed == 0 && runner.stopped == nil ? 0 : 3)
  }
}
