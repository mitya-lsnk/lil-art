import Foundation

/// Spell checking and completion for the prompt field. Everything here is optional and
/// remembered: some people write tags, some write sentences, and neither should have to
/// wade through the other's suggestions.
@available(macOS 26, *)
@MainActor
final class PromptAssist: ObservableObject {
  enum Source: String, CaseIterable, Hashable {
    case danbooru, e621

    var title: String { rawValue }
    var fileName: String { rawValue + ".csv" }
    var size: String { self == .danbooru ? "3.5 МБ" : "2.7 МБ" }
    var remote: URL {
      URL(
        string:
          "https://raw.githubusercontent.com/DominikDoom/a1111-sd-webui-tagcomplete/main/tags/\(fileName)"
      )!
    }
  }

  @Published var spellcheck = true {
    didSet { LilStore.standard.set(spellcheck, forKey: "assist.spellcheck") }
  }
  @Published var useHistory = true {
    didSet { LilStore.standard.set(useHistory, forKey: "assist.history") }
  }
  @Published private(set) var enabled: Set<Source> = [.danbooru]
  @Published private(set) var status: [Source: String] = [:]

  private var indexes: [Source: TagIndex] = [:]
  private var prompts: [String] = []
  /// `lower` is stored once: lowercasing every phrase on every keystroke was the hot spot.
  private var phrases: [(text: String, lower: String)] = []

  private var tagsDir: URL { ProjectRoot.places.tags }
  private var historyFile: URL { ProjectRoot.places.history }

  init() {
    let d = LilStore.standard
    if d.object(forKey: "assist.spellcheck") != nil { spellcheck = d.bool(forKey: "assist.spellcheck") }
    if d.object(forKey: "assist.history") != nil { useHistory = d.bool(forKey: "assist.history") }
    if let saved = d.array(forKey: "assist.sources") as? [String] {
      enabled = Set(saved.compactMap(Source.init(rawValue:)))
    }
    if let data = try? Data(contentsOf: historyFile),
      let list = try? JSONDecoder().decode([String].self, from: data)
    {
      prompts = list
      rebuildPhrases()
    }
    for source in enabled { ensure(source) }
  }

  // MARK: sources

  func isOn(_ source: Source) -> Bool { enabled.contains(source) }

  func set(_ source: Source, _ on: Bool) {
    if on {
      enabled.insert(source)
      ensure(source)
    } else {
      enabled.remove(source)
      indexes[source] = nil  // no reason to keep a hundred thousand tags in memory
      status[source] = nil
    }
    LilStore.standard.set(enabled.map(\.rawValue), forKey: "assist.sources")
  }

  private func ensure(_ source: Source) {
    guard indexes[source] == nil else { return }
    let file = tagsDir.appendingPathComponent(source.fileName)
    if FileManager.default.fileExists(atPath: file.path) {
      load(source, from: file)
      return
    }
    status[source] = "качаю \(source.size)"
    Task {
      do {
        let (temp, response) = try await URLSession.shared.download(from: source.remote)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
          status[source] = "словарь не скачался, сервер ответил \(http.statusCode)"
          return
        }
        try FileManager.default.createDirectory(at: tagsDir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: file.path) {
          try FileManager.default.removeItem(at: file)
        }
        try FileManager.default.moveItem(at: temp, to: file)
        load(source, from: file)
      } catch {
        status[source] = "словарь не скачался: \(error.localizedDescription)"
      }
    }
  }

  private func load(_ source: Source, from file: URL) {
    status[source] = "читаю словарь"
    Task.detached(priority: .utility) { [weak self] in
      let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
      let index = TagIndex.parse(text)
      await self?.install(index, for: source)
    }
  }

  private func install(_ index: TagIndex, for source: Source) {
    // the dictionary may have been switched off while it was being read
    guard enabled.contains(source) else { return }
    indexes[source] = index
    status[source] = "\(index.entries.count) тегов"
  }

  // MARK: history

  func remember(prompt: String) {
    let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    prompts.removeAll { $0 == text }
    prompts.insert(text, at: 0)
    if prompts.count > 300 { prompts.removeLast(prompts.count - 300) }
    rebuildPhrases()
    try? FileManager.default.createDirectory(
      at: ProjectRoot.places.root, withIntermediateDirectories: true)
    if let data = try? JSONEncoder().encode(prompts) {
      try? data.write(to: historyFile, options: .atomic)
    }
  }

  func clearHistory() {
    prompts = []
    phrases = []
    try? FileManager.default.removeItem(at: historyFile)
  }

  var historyCount: Int { prompts.count }

  /// Prompts are lists of pieces, so the pieces are what gets suggested, newest first.
  private func rebuildPhrases() {
    var seen = Set<String>()
    var out: [(text: String, lower: String)] = []
    collect: for prompt in prompts {
      for piece in prompt.split(whereSeparator: { ",;\n".contains($0) }) {
        let phrase = piece.trimmingCharacters(in: .whitespaces)
        guard phrase.count >= 3 else { continue }
        let lower = phrase.lowercased()
        if seen.insert(lower).inserted { out.append((phrase, lower)) }
        if out.count >= 2000 { break collect }
      }
    }
    phrases = out
  }

  // MARK: lookup

  func suggestions(for token: String, includeHistory: Bool) -> [Suggestion] {
    let query = token.trimmingCharacters(in: .whitespaces)
    guard query.count >= 2 else { return [] }
    let lowered = query.lowercased()
    var out: [Suggestion] = []
    var seen = Set<String>()

    if includeHistory, useHistory {
      let wordStart = " " + lowered
      for phrase in phrases {
        guard phrase.lower != lowered,
          phrase.lower.hasPrefix(lowered) || phrase.lower.contains(wordStart)
        else { continue }
        if seen.insert(phrase.lower).inserted {
          out.append(Suggestion(insert: phrase.text, label: "↺  " + phrase.text, appendsComma: false))
        }
        if out.count >= 5 { break }
      }
    }

    var hits: [(TagIndex.Entry, Source)] = []
    for source in Source.allCases where enabled.contains(source) {
      guard let index = indexes[source] else { continue }
      hits += index.search(query, limit: 12).map { ($0, source) }
    }
    hits.sort { $0.0.count > $1.0.count }
    for (entry, source) in hits {
      let shown = TagIndex.display(entry.name)
      guard shown.lowercased() != lowered, seen.insert(shown.lowercased()).inserted else { continue }
      let origin = source == .e621 ? "  e621" : ""
      out.append(
        Suggestion(
          insert: shown, label: "\(shown)   \(TagIndex.short(entry.count))\(origin)",
          appendsComma: true))
      if out.count >= 15 { break }
    }
    return out
  }
}
