import Foundation
import FoundationModels
import NaturalLanguage
import SwiftUI
import Translation

/// Turns a prompt written in the user's own language into English, which is what
/// the image models actually understand.
///
/// Two engines, because they have different requirements:
///  - the system translator (Translation framework) does the translating. It works on any
///    Mac and needs no Apple Intelligence;
///  - the system language model (FoundationModels) only embellishes the already-English
///    result, and only when Apple Intelligence is switched on.
@available(macOS 26, *)
@MainActor
final class Translator: ObservableObject {
  /// Which language model does the work.
  /// Who translates. None needs an account: Google through the public endpoint its own
  /// website uses, Apple entirely on this Mac, or the same local model that can improve.
  /// Google and Apple both quietly drop words they find indecent (a "лифчик" vanished without
  /// a trace); a local model does not, and the glossary below puts back what they drop.
  enum Engine: String, Hashable, CaseIterable {
    case google, system, local
    var label: String {
      switch self {
      case .google: return "Google"
      case .system: return "Apple"
      case .local: return "своя модель"
      }
    }
  }

  /// Who improves the prompt. Always something on this Mac, so no key is ever needed.
  enum Improver: String, Hashable, CaseIterable {
    case apple, local
    var label: String {
      switch self {
      case .apple: return "Apple Intelligence"
      case .local: return "своя модель"
      }
    }
  }

  /// The three local runtimes worth supporting on a Mac. All of them answer the same
  /// OpenAI-shaped requests, so only the address differs.
  enum Runtime: String, Hashable, CaseIterable {
    case ollama, lmstudio, omlx, manual

    var label: String {
      switch self {
      case .ollama: return "ollama"
      case .lmstudio: return "lm studio"
      case .omlx: return "omlx"
      case .manual: return "адрес"
      }
    }
    var endpoint: String {
      switch self {
      case .ollama: return "http://127.0.0.1:11434/v1"
      case .lmstudio: return "http://127.0.0.1:1234/v1"
      case .omlx: return "http://127.0.0.1:8000/v1"
      case .manual: return ""
      }
    }
    var install: String {
      switch self {
      case .ollama: return "ollama.com, потом ollama pull <модель>"
      case .lmstudio: return "lmstudio.ai, модель качается внутри приложения"
      case .omlx: return "brew install jundot/omlx/omlx, живёт в строке меню"
      case .manual: return "любой сервер, говорящий на языке OpenAI"
      }
    }
  }

  /// Google by default: it translates best. Without a key the Apple translator steps in.
  @Published var engine: Engine = .google {
    didSet { UserDefaults.standard.set(engine.rawValue, forKey: "llm.engine") }
  }
  @Published var improver: Improver = .apple {
    didSet { UserDefaults.standard.set(improver.rawValue, forKey: "llm.improver") }
  }
  /// Any OpenAI-compatible endpoint: mlx_lm.server, LM Studio, Ollama, llama.cpp.
  @Published var endpoint = "http://127.0.0.1:8080/v1" {
    didSet { UserDefaults.standard.set(endpoint, forKey: "llm.endpoint") }
  }
  @Published var customModel = "" {
    didSet { UserDefaults.standard.set(customModel, forKey: "llm.model") }
  }
  @Published var runtime: Runtime = .ollama {
    didSet {
      UserDefaults.standard.set(runtime.rawValue, forKey: "llm.runtime")
      if runtime != .manual { endpoint = runtime.endpoint }
      models = []
      endpointStatus = ""
    }
  }
  @Published var models: [String] = []
  @Published var endpointStatus = ""
  @Published var checking = false

  @Published var lastEnglish = ""
  @Published var note = ""

  /// Words a translator must not lose, one per line: "лифчик = bra". The Russian side is the
  /// start of the word, so "лифчик" also covers «лифчике» and «лифчиками»; the English side may
  /// list variants, "грудь = breasts/breast/chest", any of which counts as kept.
  @Published var glossary = Translator.defaultGlossary {
    didSet { UserDefaults.standard.set(glossary, forKey: "llm.glossary") }
  }

  static let defaultGlossary = """
    лифчик = bra
    бюстгальтер = bra
    трусик = panties/underwear
    трусы = underwear/panties/briefs
    трусах = underwear/panties/briefs
    стринг = thong
    бель = lingerie/underwear
    купальник = swimsuit/bathing suit
    бикини = bikini
    чулк = stockings
    колготк = pantyhose/tights
    корсет = corset
    подвязк = garter
    голая = nude/naked
    голый = nude/naked
    голую = nude/naked
    голые = nude/naked
    обнажённ = nude/naked
    обнажен = nude/naked
    грудь = breasts/breast/chest
    груди = breasts/breast/chest
    сосок = nipples/nipple
    соски = nipples/nipple
    ягодиц = buttocks/butt
    попа = butt/buttocks
    попк = butt/buttocks
    """


  /// What went wrong, for the notice card with a way out. The note stays for the status bar.
  enum Problem {
    case providerFailed(Engine, String)
    case translationFailed
    case enrichFailed(String)
  }
  var onProblem: ((Problem) -> Void)?

  /// Set to fire the SwiftUI translation task; the view hands the session back.
  @Published var configuration: TranslationSession.Configuration?

  /// One request waiting for the system translator. The session Apple hands over is tied to a
  /// language pair and does one job at a time, so requests line up here and the head is served
  /// first. Each carries its own text and its own continuation, which is what keeps a second
  /// request (the negative prompt) from ever receiving the first one's answer.
  private struct PendingItem {
    let id: Int
    let text: String
    let source: Locale.Language
    let needsPreparing: Bool
    let continuation: CheckedContinuation<String?, Never>
  }
  private var queue: [PendingItem] = []
  private var nextItemID = 0
  private var watchdog: Task<Void, Never>?

  /// Apple only hands a translation session to a SwiftUI view, so a request can sit here
  /// waiting for something that never arrives. Nothing may wait forever: this releases every
  /// waiting request and puts the machinery back in a clean state. Each one gets `nil` (no
  /// translation), so `english(for:)` returns that caller's own original text.
  func abandonPending(_ reason: String) {
    watchdog?.cancel()
    watchdog = nil
    configuration = nil
    guard !queue.isEmpty else { return }
    let items = queue
    queue = []
    note = reason
    for item in items { item.continuation.resume(returning: nil) }
  }

  init() {
    let d = UserDefaults.standard
    if let g = d.string(forKey: "llm.glossary") { glossary = g }
    if let raw = d.string(forKey: "llm.engine") {
      if let e = Engine(rawValue: raw) {
        engine = e
      } else if raw == "custom" {
        // the old "own model" choice translated and improved in one go; now it only improves
        improver = .local
      }
    }
    if let raw = d.string(forKey: "llm.improver"), let i = Improver(rawValue: raw) { improver = i }
    if let raw = d.string(forKey: "llm.runtime"), let r = Runtime(rawValue: raw) { runtime = r }
    if let u = d.string(forKey: "llm.endpoint"), !u.isEmpty { endpoint = u }
    customModel = d.string(forKey: "llm.model") ?? ""
  }

  var modelAvailable: Bool { SystemLanguageModel.default.isAvailable }

  var modelHint: String {
    switch SystemLanguageModel.default.availability {
    case .available: return ""
    case .unavailable(let reason):
      let r = String(describing: reason)
      if r.contains("appleIntelligenceNotEnabled") {
        return "включите Apple Intelligence в Настройках системы"
      }
      if r.contains("modelNotReady") { return "система ещё загружает модель" }
      if r.contains("deviceNotEligible") { return "этот мак не поддерживает" }
      return r
    }
  }

  private func looksEnglish(_ text: String) -> Bool {
    detectedLanguage(text) == "en"
  }

  /// Two-letter code of whatever the user actually typed, so we ask the system to
  /// translate from the right language instead of assuming Russian.
  private func detectedLanguage(_ text: String) -> String {
    let r = NLLanguageRecognizer()
    r.processString(text)
    return r.dominantLanguage?.rawValue ?? "ru"
  }

  /// Returns the English prompt to hand to the image model.
  ///
  /// Order matters. The on-device language model is very weak at Russian: in testing it
  /// turned a fox into a bear, "морской конёк" into "Latin horse" and "пар" into "park".
  /// So translation always goes through the system translator, which is a dedicated
  /// translation system and needs no Apple Intelligence. The language model is only asked
  /// to embellish text that is already English, which is what it is actually good at.
  func english(for text: String, improve: Bool = false) async -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      lastEnglish = ""
      note = ""
      return text
    }

    var english = trimmed
    var steps: [String] = []

    if looksEnglish(trimmed) {
      steps.append("уже по-английски")
    } else {
      var translated: String?
      if engine == .local {
        translated = await viaCustomTranslation(trimmed)
        if translated != nil {
          steps.append("перевела своя модель")
        } else {
          onProblem?(.providerFailed(.local, endpointStatus))
        }
      }
      if engine == .google {
        translated = await viaGoogleTranslate(trimmed)
        if translated != nil {
          steps.append("перевёл Google")
        } else {
          onProblem?(.providerFailed(.google, endpointStatus))
        }
      }
      if translated == nil {
        // a caller that already gave up must not start a system translation nobody waits for
        guard !Task.isCancelled else { return text }
        if let viaApple = await viaSystemTranslator(trimmed) {
          translated = viaApple
          steps.append("перевёл Apple")
        }
      }
      guard let translated else {
        note = "перевести не вышло, отдаю как есть"
        onProblem?(.translationFailed)
        lastEnglish = ""
        return text
      }
      english = Self.keepingTerms(of: trimmed, in: translated, glossary: glossary)
    }

    if improve {
      switch improver {
      case .apple:
        if !modelAvailable {
          steps.append("улучшение недоступно")
          onProblem?(.enrichFailed(modelHint))
        } else if let richer = await viaLanguageModel(english) {
          english = richer
          steps.append("улучшила Apple Intelligence")
        } else {
          steps.append("улучшить не вышло")
          onProblem?(
            .enrichFailed(
              languageModelFailure.isEmpty ? "Apple Intelligence не ответила" : languageModelFailure))
        }
      case .local:
        if let richer = await viaCustomLLM(english) {
          english = richer
          steps.append("улучшила своя модель")
        } else {
          steps.append("улучшить не вышло")
          onProblem?(.enrichFailed("своя модель не ответила: \(endpointStatus)"))
        }
      }
    }

    // the improver may drop a word just the same
    if improve { english = Self.keepingTerms(of: trimmed, in: english, glossary: glossary) }
    note = steps.joined(separator: ", ")
    lastEnglish = english == trimmed ? "" : english
    return english
  }

  /// Puts back every glossary word the translation lost: a Russian word that starts with an
  /// entry's left side, with none of the entry's English in the result, gets that English added
  /// at the end. Out of place, but there, which is what the picture needs.
  static func keepingTerms(of source: String, in english: String, glossary: String) -> String {
    let words = source.lowercased().replacingOccurrences(of: "ё", with: "е")
      .components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
    let lowered = english.lowercased()
    var missing: [String] = []
    for line in glossary.split(whereSeparator: \.isNewline) {
      let sides = line.split(separator: "=", maxSplits: 1).map {
        $0.trimmingCharacters(in: .whitespaces)
      }
      guard sides.count == 2, !sides[0].isEmpty, !sides[1].isEmpty else { continue }
      let stem = sides[0].lowercased().replacingOccurrences(of: "ё", with: "е")
      // "breasts/breast/chest": any of them counts, the first is what gets added
      let terms = sides[1].split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
      guard let term = terms.first, words.contains(where: { $0.hasPrefix(stem) }) else { continue }
      // "bra" is in "bracelet" and "zebra": only a whole word counts as present
      let present = terms.contains { candidate in
        lowered.range(
          of: "\\b\(NSRegularExpression.escapedPattern(for: candidate.lowercased()))\\b",
          options: .regularExpression) != nil
      }
      if !present, !missing.contains(term) { missing.append(term) }
    }
    guard !missing.isEmpty else { return english }
    let trimmed = english.trimmingCharacters(in: .whitespacesAndNewlines)
    let joiner = trimmed.hasSuffix(".") || trimmed.hasSuffix(",") ? " " : ", "
    return trimmed + joiner + missing.joined(separator: ", ")
  }

  private static let enrichInstructions = """
    You expand short English image prompts. Keep every subject, object and adjective the \
    author wrote, in the same order, then add concrete visual detail: lighting, materials, \
    texture, lens, mood. Never replace or remove anything the author named. Never invent a \
    different subject. Stay under 60 words. Reply with the prompt only.
    """

  // MARK: system language model

  /// Why the system model said no last time, in words for the notice.
  private(set) var languageModelFailure = ""

  /// The system model with the guardrails Apple provides for rewriting a person's own text:
  /// the default ones refuse much of what an image prompt can be about.
  private func viaLanguageModel(_ english: String) async -> String? {
    languageModelFailure = ""
    do {
      let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
      let session = LanguageModelSession(model: model, instructions: Self.enrichInstructions)
      let reply = try await session.respond(to: english)
      let out = reply.content.trimmingCharacters(in: .whitespacesAndNewlines)
      if out.isEmpty { languageModelFailure = "Apple Intelligence вернула пустой ответ" }
      return out.isEmpty ? nil : out
    } catch let error as LanguageModelSession.GenerationError {
      switch error {
      case .guardrailViolation, .refusal:
        languageModelFailure =
          "Apple Intelligence отказалась: тема вне её правил. Для таких тем выберите «своя модель»"
      case .assetsUnavailable:
        languageModelFailure = "модель Apple ещё не загрузилась, попробуйте позже"
      case .rateLimited, .concurrentRequests:
        languageModelFailure = "Apple Intelligence занята, нажмите ещё раз через пару секунд"
      case .unsupportedLanguageOrLocale:
        languageModelFailure = "Apple Intelligence не работает с этим языком"
      case .exceededContextWindowSize:
        languageModelFailure = "Prompt слишком длинный для Apple Intelligence"
      default:
        languageModelFailure = "Apple Intelligence: \(error.localizedDescription)"
      }
      return nil
    } catch {
      languageModelFailure = "Apple Intelligence: \(error.localizedDescription)"
      return nil
    }
  }

  // MARK: google translate

  /// The public endpoint the Google Translate website itself uses: free and without a key. It
  /// is not an official API, so Google may limit it; when it fails, Apple translates instead.
  /// The text goes in the request body, never in the address.
  private func viaGoogleTranslate(_ text: String) async -> String? {
    guard
      let url = URL(
        string: "https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=en&dt=t")
    else { return nil }
    var request = URLRequest(url: url, timeoutInterval: 15)
    request.httpMethod = "POST"
    request.setValue(
      "application/x-www-form-urlencoded;charset=utf-8", forHTTPHeaderField: "Content-Type")
    let unreserved = CharacterSet(
      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
    let encoded = text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    request.httpBody = Data(("q=" + encoded).utf8)
    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        endpointStatus = "Google ответил \(http.statusCode)"
        return nil
      }
      guard let json = try JSONSerialization.jsonObject(with: data) as? [Any],
        let segments = json.first as? [Any]
      else {
        endpointStatus = "непонятный ответ Google"
        return nil
      }
      let joined = segments.compactMap { ($0 as? [Any])?.first as? String }.joined()
      let cleaned = joined.trimmingCharacters(in: .whitespacesAndNewlines)
      return cleaned.isEmpty ? nil : cleaned
    } catch {
      endpointStatus = "Google недоступен: \(error.localizedDescription)"
      return nil
    }
  }

  // MARK: your own model over HTTP

  private static let translateInstructions = """
    Translate the user's text into English for an image generation prompt. Translate every \
    word literally, including clothing, anatomy and explicit words; never soften, skip or \
    censor anything. Keep the order and punctuation. Reply with the translation only.
    """

  private func viaCustomTranslation(_ text: String) async -> String? {
    guard let out = await chat(system: Self.translateInstructions, user: text, timeout: 60)
    else { return nil }
    let cleaned = out.trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned.isEmpty ? nil : cleaned
  }

  /// Talks to an OpenAI-compatible endpoint on this machine. Nothing leaves the Mac
  /// unless the user points this at a remote address themselves.
  private func viaCustomLLM(_ english: String) async -> String? {
    guard
      let out = await chat(system: Self.enrichInstructions, user: english, timeout: 60)
    else { return nil }
    let cleaned = out.trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned.isEmpty ? nil : cleaned
  }

  private func chat(system: String, user: String, timeout: TimeInterval) async -> String? {
    guard var url = URL(string: endpoint) else { return nil }
    if !url.path.hasSuffix("/chat/completions") {
      url = url.appendingPathComponent("chat/completions")
    }
    var request = URLRequest(url: url, timeoutInterval: timeout)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    var body: [String: Any] = [
      "messages": [
        ["role": "system", "content": system],
        ["role": "user", "content": user],
      ],
      "temperature": 0.2,
      "stream": false,
    ]
    if !customModel.isEmpty { body["model"] = customModel }
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)

    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        endpointStatus = "сервер ответил \(http.statusCode)"
        return nil
      }
      guard
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let choices = json["choices"] as? [[String: Any]],
        let message = choices.first?["message"] as? [String: Any],
        let content = message["content"] as? String
      else {
        endpointStatus = "непонятный ответ сервера"
        return nil
      }
      return content
    } catch {
      endpointStatus = "не достучался: \(error.localizedDescription)"
      return nil
    }
  }

  /// GET {endpoint}/models — every OpenAI-shaped server answers this, so it doubles as
  /// both a liveness probe and the model list.
  private func fetchModels(at base: String, timeout: TimeInterval = 3) async -> [String]? {
    guard var url = URL(string: base) else { return nil }
    if !url.path.hasSuffix("/models") { url = url.appendingPathComponent("models") }
    var request = URLRequest(url: url, timeoutInterval: timeout)
    request.httpMethod = "GET"
    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
      else { return nil }
      guard
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let list = json["data"] as? [[String: Any]]
      else { return [] }
      return list.compactMap { $0["id"] as? String }.sorted()
    } catch {
      return nil
    }
  }

  /// Looks at all three known ports and settles on whichever is actually running.
  func detectRuntime() async {
    checking = true
    endpointStatus = "ищу запущенный сервер"
    for candidate in [Runtime.ollama, .lmstudio, .omlx] {
      if let found = await fetchModels(at: candidate.endpoint, timeout: 2) {
        runtime = candidate
        endpoint = candidate.endpoint
        models = found
        if customModel.isEmpty, let first = found.first { customModel = first }
        endpointStatus =
          found.isEmpty
          ? "\(candidate.label) отвечает, но моделей в нём нет"
          : "\(candidate.label): \(found.count) модел(ей)"
        checking = false
        return
      }
    }
    endpointStatus = "ни один из трёх не запущен"
    checking = false
  }

  func refreshModels() async {
    checking = true
    if let found = await fetchModels(at: endpoint) {
      models = found
      if customModel.isEmpty, let first = found.first { customModel = first }
      endpointStatus = found.isEmpty ? "сервер отвечает, моделей нет" : "моделей: \(found.count)"
    } else {
      models = []
      endpointStatus = "сервер по этому адресу не отвечает"
    }
    checking = false
  }

  /// Settings button: say plainly whether the endpoint is alive and which model answers.
  func testEndpoint() async {
    checking = true
    endpointStatus = "проверяю"
    let started = Date()
    if let reply = await chat(
      system: "Reply with the single word: ok", user: "ping", timeout: 20)
    {
      let secs = Date().timeIntervalSince(started)
      endpointStatus = String(
        format: "работает, ответ за %.1f с: %@", secs,
        reply.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40).description)
    } else if endpointStatus == "проверяю" {
      endpointStatus = "не отвечает"
    }
    checking = false
  }

  // MARK: system translator

  private func viaSystemTranslator(_ text: String) async -> String? {
    guard !Task.isCancelled else { return nil }

    let code = detectedLanguage(text)
    let source = Locale.Language(identifier: code)
    let target = Locale.Language(identifier: "en")

    var needsPreparing = false
    switch await LanguageAvailability().status(from: source, to: target) {
    case .unsupported:
      note = "система не умеет переводить с этого языка"
      return nil
    case .supported:
      needsPreparing = true
      note = "языки перевода ещё не скачаны, система спросит разрешение"
    case .installed:
      break
    @unknown default:
      break
    }
    guard !Task.isCancelled else { return nil }

    let id = nextItemID
    nextItemID += 1
    // If the caller is cancelled while waiting, its place in the line is given up and it is
    // resumed at once: nobody may hang on a session that may never come.
    return await withTaskCancellationHandler {
      await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
        if Task.isCancelled {
          c.resume(returning: nil)
          return
        }
        queue.append(
          PendingItem(
            id: id, text: text, source: source, needsPreparing: needsPreparing, continuation: c))
        // only an empty line needs a kick; otherwise the head's turn ends by presenting the next
        if queue.count == 1 { presentHead() }
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.resolve(id, with: nil) }
    }
  }

  /// Asks SwiftUI for a session for the request at the head of the line.
  private func presentHead() {
    watchdog?.cancel()
    watchdog = nil
    guard let head = queue.first else {
      configuration = nil
      return
    }
    var config = TranslationSession.Configuration(
      source: head.source, target: Locale.Language(identifier: "en"))
    config.invalidate()
    configuration = config

    watchdog = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 12_000_000_000)
      guard !Task.isCancelled else { return }
      self?.abandonPending("системный переводчик не ответил за 12 секунд")
    }
  }

  /// Ends one request. Whoever removes it from the line is the only one who resumes it, so a
  /// continuation can never be resumed twice or left behind.
  private func resolve(_ id: Int, with result: String?) {
    guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
    let item = queue.remove(at: index)
    item.continuation.resume(returning: result)
    // the next request gets its turn (or the line is closed) when the head has been served
    if index == 0 { presentHead() }
  }

  /// Called by the view once SwiftUI hands over a live session.
  func fulfill(with session: TranslationSession) async {
    // serves the head only; the session was requested for its language pair
    guard let head = queue.first else { return }
    watchdog?.cancel()
    watchdog = nil
    do {
      if head.needsPreparing { try await session.prepareTranslation() }
      let response = try await session.translate(head.text)
      resolve(head.id, with: response.targetText.isEmpty ? nil : response.targetText)
    } catch {
      // the request may already be gone (abandoned or cancelled), and a failure of this stale
      // session says nothing about whatever is waiting now
      if queue.contains(where: { $0.id == head.id }) {
        note = "системный перевод не вышел: \(error.localizedDescription)"
      }
      resolve(head.id, with: nil)
    }
  }
}
