import Foundation

/// Everything the command-line generator decides from its arguments before it touches an
/// engine, with no engine in it: the flags, their limits and the messages for a wrong one.

struct Fail: Error, CustomStringConvertible {
  let description: String
  init(_ message: String) { description = message }
}

struct Arguments {
  static let withValue: Set<String> = [
    "--prompt", "--prompt-file", "--negative", "--model", "--width", "--height", "--steps", "--cfg",
    "--sampler", "--seed", "--out", "--jobs", "--out-dir", "--limit", "--timeout", "--port", "--sheet",
    "--import-part", "--check-part", "--squeeze", "--plan",
    "--image", "--mask", "--ref", "--strength", "--count", "--upscaler", "--upscale-factor", "--mask-blur", "--mask-outset", "--lora",
  ]
  static let switches: Set<String> = ["--dry-run", "--help", "-h", "--fresh"]

  var values: [String: String] = [:]
  var flags: Set<String> = []

  init(_ list: [String]) throws {
    var i = 0
    while i < list.count {
      let arg = list[i]
      if Self.switches.contains(arg) {
        flags.insert(arg)
      } else if Self.withValue.contains(arg) {
        guard i + 1 < list.count else { throw Fail("после \(arg) нужно значение") }
        guard values[arg] == nil else { throw Fail("\(arg) указан дважды") }
        values[arg] = list[i + 1]
        i += 1
      } else {
        throw Fail("неизвестный флаг \(arg) (список: lilart-gen --help)")
      }
      i += 1
    }
  }

  subscript(_ flag: String) -> String? { values[flag] }

  func int(_ flag: String) throws -> Int? {
    guard let raw = values[flag] else { return nil }
    guard let v = Int(raw) else { throw Fail("\(flag): ждали целое число, получили «\(raw)»") }
    return v
  }
}

/// The engine refuses sizes that are not multiples of 64 (16 is not enough), and does so
/// only after the request is sent — so it is checked here, before any GPU time is spent.
func checkSize(_ value: Int, _ what: String) throws -> Int {
  guard value % 64 == 0, (64...4096).contains(value) else {
    let near = max(64, min(4096, Int((Double(value) / 64).rounded()) * 64))
    throw Fail("\(what) = \(value): нужно кратное 64 от 64 до 4096 (ближайшее: \(near))")
  }
  return value
}

func parseSeed(_ raw: String) throws -> UInt32 {
  guard let v = UInt32(raw) else { throw Fail("--seed: целое от 0 до \(UInt32.max), получили «\(raw)»") }
  return v
}

// MARK: - jobs

struct Job {
  let id: String
  let prompt: String
  let count: Int
  let seed: UInt32?
  let width: Int
  let height: Int
}

func loadJobs(
  _ path: String, width: Int, height: Int, warn: (String) -> Void = { _ in }
) throws -> [Job] {
  guard let data = FileManager.default.contents(atPath: path) else { throw Fail("не открылся \(path)") }
  let raw: Any
  do { raw = try JSONSerialization.jsonObject(with: data) } catch {
    throw Fail("\(path): это не JSON (\(error.localizedDescription))")
  }
  guard let list = raw as? [[String: Any]] else { throw Fail("\(path): ждали список объектов [{id, prompt, count}]") }
  guard !list.isEmpty else { throw Fail("\(path): список пуст") }
  let known: Set<String> = ["id", "prompt", "count", "seed", "width", "height"]
  var jobs: [Job] = []
  for (index, item) in list.enumerated() {
    let place = "\(path), задание \(index + 1)"
    guard let id = item["id"] as? String,
      id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$"#, options: .regularExpression) != nil
    else {
      throw Fail("\(place): id нужен строкой из латиницы, цифр, . _ - (он же имя папки)")
    }
    guard let prompt = (item["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
      !prompt.isEmpty
    else { throw Fail("\(place) (\(id)): пустой prompt") }
    func number(_ key: String) throws -> Int? {
      guard let value = item[key] else { return nil }
      guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
        n.doubleValue == n.doubleValue.rounded()
      else { throw Fail("\(place) (\(id)): \(key) должен быть целым числом") }
      return n.intValue
    }
    let count = try number("count") ?? 1
    guard count >= 1 else { throw Fail("\(place) (\(id)): count должен быть от 1") }
    var seed: UInt32?
    if let s = try number("seed") {
      guard let v = UInt32(exactly: s) else { throw Fail("\(place) (\(id)): seed от 0 до \(UInt32.max)") }
      seed = v
    }
    let w = try checkSize(try number("width") ?? width, "\(id): width")
    let h = try checkSize(try number("height") ?? height, "\(id): height")
    let extra = Set(item.keys).subtracting(known)
    if !extra.isEmpty {
      warn("внимание: \(id): поля \(extra.sorted().joined(separator: ", ")) не поддерживаются и пропущены")
    }
    jobs.append(Job(id: id, prompt: prompt, count: count, seed: seed, width: w, height: h))
  }
  return jobs
}

/// Variants already in an id's folder: `<id>_<n>_<seed>.png`, by n. New ones continue the
/// numbering, so a second round never overwrites the first and the sheet shows both.
func variants(of id: String, in dir: URL) -> [(n: Int, url: URL)] {
  let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
  var found: [(Int, URL)] = []
  for name in names where name.hasPrefix(id + "_") && name.hasSuffix(".png") {
    let rest = name.dropFirst(id.count + 1).dropLast(4)
    let parts = rest.split(separator: "_")
    guard parts.count == 2, let n = Int(parts[0]), UInt32(parts[1]) != nil else { continue }
    found.append((n, dir.appendingPathComponent(name)))
  }
  return found.sorted { $0.0 < $1.0 }.map { (n: $0.0, url: $0.1) }
}
