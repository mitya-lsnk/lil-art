import Foundation
import Testing
@testable import LilArtCore

private func env(
  appPort: Int = 0, existing: Set<String> = [], texts: [String: String] = [:]
) -> GenCommand.Environment {
  var e = GenCommand.Environment()
  e.appPort = appPort
  e.modelsDir = URL(fileURLWithPath: "/models")
  // the default model is always installed unless a test says otherwise
  let present = existing.union(["/models/krea_2_turbo_q8p.ckpt"])
  e.fileExists = { present.contains($0) }
  e.readText = { texts[$0] }
  return e
}

private func parse(_ line: String, _ e: GenCommand.Environment = env()) throws -> GenCommand {
  try GenCommand.parse(line.split(separator: " ").map(String.init), e)
}

private func failure(_ line: String, _ e: GenCommand.Environment = env()) -> String? {
  do { _ = try parse(line, e); return nil } catch { return "\(error)" }
}

private func run(_ line: String, _ e: GenCommand.Environment = env()) throws -> GenRun {
  guard case .generate(let run) = try parse(line, e) else { throw Fail("not a run") }
  return run
}

@Suite struct ArgumentsTests {
  @Test func flagsAndValuesAreSeparated() throws {
    let a = try Arguments(["--prompt", "x", "--dry-run", "--seed", "5"])
    #expect(a["--prompt"] == "x" && a["--seed"] == "5")
    #expect(a.flags == ["--dry-run"])
  }

  @Test func theMistakesPeopleMakeAreNamed() {
    #expect(failure("--bogus 1") == "неизвестный флаг --bogus (список: lilart-gen --help)")
    #expect(failure("--prompt") == "после --prompt нужно значение")
    #expect(failure("--prompt a --prompt b") == "--prompt указан дважды")
    #expect(failure("--width abc --prompt a") == "--width: ждали целое число, получили «abc»")
  }

  @Test func sizesMustBeMultiplesOf64AndTheNearestIsSuggested() throws {
    #expect(try checkSize(1024, "w") == 1024)
    #expect(throws: Fail.self) { try checkSize(1000, "--width") }
    do { _ = try checkSize(1000, "--width") } catch {
      #expect("\(error)" == "--width = 1000: нужно кратное 64 от 64 до 4096 (ближайшее: 1024)")
    }
    #expect(throws: Fail.self) { try checkSize(8192, "w") }
    #expect(throws: Fail.self) { try checkSize(0, "w") }
  }

  @Test func seedsAreWholeNumbersUpTo32Bits() throws {
    #expect(try parseSeed("0") == 0)
    #expect(try parseSeed("4294967295") == UInt32.max)
    #expect(throws: Fail.self) { try parseSeed("4294967296") }
    #expect(throws: Fail.self) { try parseSeed("-1") }
    #expect(throws: Fail.self) { try parseSeed("x") }
  }
}

@Suite struct GenCommandRoutingTests {
  @Test func aBareCallPrintsUsageAsAFailureButHelpDoesNot() throws {
    #expect(try GenCommand.parse([], env()) == .help(failed: true))
    #expect(try GenCommand.parse(["--help"], env()) == .help(failed: false))
    #expect(try GenCommand.parse(["-h", "--prompt", "x"], env()) == .help(failed: false))
    // flags alone, no values: usage, but not an error exit
    #expect(try GenCommand.parse(["--dry-run"], env()) == .help(failed: false))
  }

  @Test func sheetKnowsWhetherItCameAlone() throws {
    #expect(try parse("--sheet /out/hero") == .sheet(dir: URL(fileURLWithPath: "/out/hero"), alone: true))
    #expect(try parse("--sheet /out/hero --seed 1") == .sheet(dir: URL(fileURLWithPath: "/out/hero"), alone: false))
  }

  @Test func partCheckAndImportMustComeAlone() throws {
    #expect(try parse("--check-part /a.safetensors") == .part(source: URL(fileURLWithPath: "/a.safetensors"), checkOnly: true))
    #expect(try parse("--import-part /a.safetensors") == .part(source: URL(fileURLWithPath: "/a.safetensors"), checkOnly: false))
    #expect(failure("--import-part /a.safetensors --seed 1") == "--check-part и --import-part ни с чем не сочетаются")
  }

  @Test func squeezeNeedsAnOutputAndReadsThePlan() throws {
    #expect(failure("--squeeze m.ckpt") == "для --squeeze нужен --out")
    #expect(try parse("--squeeze m.ckpt --out c.ckpt")
      == .squeeze(input: "m.ckpt", out: "c.ckpt", bits: 8, importantBits: 8, edgeBlocks: 0))
    #expect(try parse("--squeeze m.ckpt --out c.ckpt --plan 4/8")
      == .squeeze(input: "m.ckpt", out: "c.ckpt", bits: 4, importantBits: 8, edgeBlocks: 2))
    #expect(try parse("--squeeze m.ckpt --out c.ckpt --plan 6")
      == .squeeze(input: "m.ckpt", out: "c.ckpt", bits: 6, importantBits: 6, edgeBlocks: 0))
  }
}

@Suite struct GenRunTests {
  @Test func aSingleRunGetsTheDocumentedDefaults() throws {
    let r = try run("--prompt cat --seed 7")
    #expect(r.port == 7859 && r.width == 1024 && r.height == 1024 && r.timeout == 600)
    #expect(r.model == "krea_2_turbo_q8p.ckpt")
    guard case .single(let s) = r.mode else { throw Fail("not single") }
    #expect(s.prompt == "cat" && s.seed == 7 && s.count == 1 && s.edit == GenRun.Edit())
    #expect(s.loras.isEmpty && s.upscaler == nil && s.upscaleFactor == 2)
    #expect(s.out.lastPathComponent == "lilart_7.png")
  }

  @Test func theAppsPortIsUsedWhenItIsValid() throws {
    #expect(try run("--prompt a", env(appPort: 7000)).port == 7000)
    #expect(try run("--prompt a", env(appPort: 99999)).port == 7859)
    #expect(try run("--prompt a --port 8000", env(appPort: 7000)).port == 8000)
    #expect(failure("--prompt a --port 70000") == "--port вне 1…65535")
  }

  @Test func everyLimitHasItsMessage() {
    #expect(failure("--prompt a --steps 0") == "--steps от 1 до 150")
    #expect(failure("--prompt a --steps 151") == "--steps от 1 до 150")
    #expect(failure("--prompt a --cfg 51") == "--cfg: число от 0 до 50")
    #expect(failure("--prompt a --cfg nan") == "--cfg: число от 0 до 50")
    #expect(failure("--prompt a --timeout 5") == "--timeout: секунды, не меньше 10")
    #expect(failure("--prompt a --limit 0") == "--limit должен быть от 1")
    #expect(failure("--prompt a --count 9") == "--count от 1 до 8")
    #expect(failure("--prompt a --out x.jpg") == "--out должен кончаться на .png")
    #expect(failure("--prompt a --mask-blur 65") == "--mask-blur: 0…64")
    #expect(failure("--prompt a --width 100") != nil)
  }

  @Test func aMissingModelFileIsReportedBeforeAnyWork() {
    #expect(failure("--prompt a --model nope.ckpt") == "модели nope.ckpt нет в /models")
    // a model that is not a file (an engine-side name) is not looked for on disk
    #expect(failure("--prompt a --model builtin") == nil)
    #expect(failure("--prompt a --model m.ckpt", env(existing: ["/models/m.ckpt"])) == nil)
  }

  @Test func loraAndUpscalerFilesMustExistAndWeightsAreRead() throws {
    let e = env(existing: ["/models/a.ckpt", "/models/b.ckpt", "/models/up.ckpt"])
    let r = try run("--prompt x --lora a.ckpt:0.8,b.ckpt --upscaler up.ckpt --upscale-factor 4", e)
    guard case .single(let s) = r.mode else { throw Fail("x") }
    #expect(s.loras == [.init(file: "a.ckpt", weight: 0.8), .init(file: "b.ckpt", weight: 1)])
    #expect(s.upscaler == "up.ckpt" && s.upscaleFactor == 4)
    #expect(failure("--prompt x --lora gone.ckpt", e) == "LoRA gone.ckpt нет в /models")
    #expect(failure("--prompt x --upscaler gone.ckpt", e) == "апскейлера gone.ckpt нет в /models")
    #expect(failure("--prompt x --upscaler up.ckpt --upscale-factor 3", e) == "--upscale-factor: 2 или 4")
  }

  @Test func countAndMaskOptionsAreCarried() throws {
    let e = env(existing: ["in.png", "m.png", "ref.png"])
    let r = try run("--prompt x --count 3 --image in.png --mask m.png --ref ref.png --strength 0.5 --fresh --mask-blur 4 --mask-outset 8 --seed 1 --out /o/p.png", e)
    guard case .single(let s) = r.mode else { throw Fail("x") }
    #expect(s.count == 3 && s.maskBlur == 4 && s.maskOutset == 8 && s.out.path == "/o/p.png")
    #expect(s.edit == GenRun.Edit(image: "in.png", mask: "m.png", ref: "ref.png", strength: 0.5, fresh: true))
  }

  @Test func theLimitIsKeptForTheRunnerToApply() throws {
    #expect(try run("--prompt a --limit 2").limit == 2)
    #expect(try run("--prompt a").limit == nil)
  }

  @Test func theSamplerIsPassedOnAsTheNameTyped() throws {
    #expect(try run("--prompt x --sampler DDIM").sampler == "DDIM")
  }

  @Test func aPromptFileIsReadAndTrimmedAndCannotBeCombinedWithAPrompt() throws {
    let e = env(texts: ["/p.txt": "  a long\nprompt \n"])
    guard case .single(let s) = try run("--prompt-file /p.txt", e).mode else { throw Fail("x") }
    #expect(s.prompt == "a long\nprompt")
    #expect(failure("--prompt-file /p.txt --prompt a", e) == "либо --prompt, либо --prompt-file")
    #expect(failure("--prompt-file /nope.txt", e) == "не прочитался /nope.txt")
  }

  @Test func editFlagsNeedTheirPictureAndRealFiles() {
    let e = env(existing: ["in.png"])
    #expect(failure("--prompt a --mask m.png", e) == "--mask и --strength работают только вместе с --image")
    #expect(failure("--prompt a --strength 0.5", e) == "--mask и --strength работают только вместе с --image")
    #expect(failure("--prompt a --image gone.png", e) == "нет файла gone.png")
    #expect(failure("--prompt a --image in.png --ref gone.png", e) == "нет файла gone.png")
    #expect(failure("--prompt a --image in.png --strength 0", e) == "--strength: число больше 0 и не больше 1")
    #expect(failure("--prompt a --image in.png --strength 1.1", e) == "--strength: число больше 0 и не больше 1")
    #expect(failure("--prompt a --image in.png --strength 1", e) == nil)
  }

  @Test func aMissingPromptIsReported() {
    #expect(failure("--seed 1") == "нужен --prompt или --prompt-file (или --jobs)")
  }

  @Test func aBatchNeedsItsFolderAndACeilingAndRefusesSingleOnlyFlags() throws {
    let r = try run("--jobs j.json --out-dir /o --limit 5")
    #expect(r.mode == .batch(jobsPath: "j.json", outDir: "/o", limit: 5))
    #expect(failure("--jobs j.json --limit 5") == "для --jobs нужен --out-dir")
    #expect(failure("--jobs j.json --out-dir /o") == "для --jobs нужен --limit N — жёсткий потолок генераций за запуск")
    #expect(failure("--jobs j.json --out-dir /o --limit 5 --prompt a")
      == "--prompt не сочетается с --jobs: промпт, сид и имена файлов берутся из заданий")
    #expect(failure("--prompt a --out-dir /o") == "--out-dir только вместе с --jobs; для одной картинки --out")
  }

  @Test func dryRunAndNegativeArePassedOn() throws {
    let r = try run("--prompt a --negative bad --dry-run")
    #expect(r.dryRun && r.negative == "bad")
  }
}

@Suite struct JobsFileTests {
  private func file(_ json: String) -> String {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
    try! Data(json.utf8).write(to: url)
    return url.path
  }

  @Test func aGoodFileGivesJobsWithDefaultsFilledIn() throws {
    let jobs = try loadJobs(file(#"[{"id":"hero","prompt":" a hero ","count":2,"seed":5,"width":512}]"#), width: 1024, height: 768)
    #expect(jobs.count == 1)
    #expect(jobs[0].prompt == "a hero" && jobs[0].count == 2 && jobs[0].seed == 5)
    #expect(jobs[0].width == 512 && jobs[0].height == 768)
    let plain = try loadJobs(file(#"[{"id":"a.b-c_1","prompt":"p"}]"#), width: 64, height: 64)
    #expect(plain[0].count == 1 && plain[0].seed == nil)
  }

  @Test func unknownFieldsAreWarnedAboutAndSkipped() throws {
    var warned: [String] = []
    _ = try loadJobs(file(#"[{"id":"a","prompt":"p","mood":"x","zeta":1}]"#), width: 64, height: 64, warn: { warned.append($0) })
    #expect(warned == ["внимание: a: поля mood, zeta не поддерживаются и пропущены"])
  }

  @Test func everyBadFileIsRefusedWithAReason() {
    func message(_ json: String) -> String? {
      do { _ = try loadJobs(file(json), width: 64, height: 64); return nil } catch { return "\(error)" }
    }
    #expect(message("not json")?.contains("это не JSON") == true)
    #expect(message(#"{"a":1}"#)?.contains("ждали список объектов") == true)
    #expect(message("[]")?.contains("список пуст") == true)
    #expect(message(#"[{"id":"../x","prompt":"p"}]"#)?.contains("id нужен строкой") == true)
    #expect(message(#"[{"id":"a","prompt":"  "}]"#)?.contains("пустой prompt") == true)
    #expect(message(#"[{"id":"a","prompt":"p","count":0}]"#)?.contains("count должен быть от 1") == true)
    #expect(message(#"[{"id":"a","prompt":"p","count":1.5}]"#)?.contains("count должен быть целым") == true)
    #expect(message(#"[{"id":"a","prompt":"p","count":true}]"#)?.contains("count должен быть целым") == true)
    #expect(message(#"[{"id":"a","prompt":"p","seed":-1}]"#)?.contains("seed от 0 до") == true)
    #expect(message(#"[{"id":"a","prompt":"p","width":100}]"#)?.contains("a: width") == true)
  }

  @Test func aMissingFileIsReported() {
    #expect(throws: Fail.self) { try loadJobs("/nonexistent/j.json", width: 64, height: 64) }
  }
}

@Suite struct VariantsTests {
  @Test func existingVariantsAreFoundInOrderSoNewOnesContinueTheNumbering() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for name in ["hero_2_55.png", "hero_1_7.png", "hero_sheet.png", "hero_x_1.png", "other_1_1.png", "hero_3_9.jpg", "hero_10_4.png"] {
      try Data([1]).write(to: dir.appendingPathComponent(name))
    }
    #expect(variants(of: "hero", in: dir).map(\.n) == [1, 2, 10])
    #expect(variants(of: "nobody", in: dir).isEmpty)
    #expect(variants(of: "hero", in: URL(fileURLWithPath: "/nonexistent")).isEmpty)
  }
}
