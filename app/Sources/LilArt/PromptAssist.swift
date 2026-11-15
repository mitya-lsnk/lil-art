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
  @Published private(set) var enabled: Set<Source> = [.danbooru]
  @Published private(set) var status: [Source: String] = [:]

  private var indexes: [Source: TagIndex] = [:]

  private var tagsDir: URL { ProjectRoot.places.tags }

  init() {
    let d = LilStore.standard
    if d.object(forKey: "assist.spellcheck") != nil { spellcheck = d.bool(forKey: "assist.spellcheck") }
    if let saved = d.array(forKey: "assist.sources") as? [String] {
      enabled = Set(saved.compactMap(Source.init(rawValue:)))
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

  // MARK: lookup

  func suggestions(for token: String) -> [Suggestion] {
    let query = token.trimmingCharacters(in: .whitespaces)
    guard query.count >= 2 else { return [] }
    let lowered = query.lowercased()
    var out: [Suggestion] = []
    var seen = Set<String>()

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
