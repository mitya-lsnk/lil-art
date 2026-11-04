
import Foundation
final class TagIndex: @unchecked Sendable {
  struct Entry {
    let name: String
    let count: Int
  }

  let entries: [Entry]
  private let keys: [String]
  private let targets: [Int32]

  private init(entries: [Entry], keys: [String], targets: [Int32]) {
    self.entries = entries
    self.keys = keys
    self.targets = targets
  }

  static func parse(_ text: String) -> TagIndex {
    var entries: [Entry] = []
    entries.reserveCapacity(120_000)
    var pairs: [(String, Int32)] = []
    pairs.reserveCapacity(420_000)

    text.enumerateLines { line, _ in
      let parts = line.split(separator: ",", maxSplits: 3, omittingEmptySubsequences: false)
      guard parts.count >= 3, !parts[0].isEmpty, !parts[0].hasPrefix("\""),
        let count = Int(parts[2])
      else { return }
      let name = String(parts[0])
      let index = Int32(entries.count)
      entries.append(Entry(name: name, count: count))

      let lower = name.lowercased()
      pairs.append((lower, index))
      // "hair" should find "long_hair", not only tags that start with it
      for word in lower.split(separator: "_").dropFirst() where word.count >= 2 {
        pairs.append((String(word), index))
      }
      if parts.count == 4 {
        let aliases = parts[3].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        for alias in aliases.split(separator: ",") where alias.count >= 2 {
          pairs.append((alias.lowercased(), index))
        }
      }
    }

    pairs.sort { $0.0 < $1.0 }
    return TagIndex(entries: entries, keys: pairs.map(\.0), targets: pairs.map(\.1))
  }

  func search(_ raw: String, limit: Int) -> [Entry] {
    let query = raw.lowercased().replacingOccurrences(of: " ", with: "_")
    guard query.count >= 2 else { return [] }

    var low = 0
    var high = keys.count
    while low < high {
      let mid = (low + high) / 2
      if keys[mid] < query { low = mid + 1 } else { high = mid }
    }

    var seen = Set<Int32>()
    var i = low
    var scanned = 0
    while i < keys.count, keys[i].hasPrefix(query), scanned < 4000 {
      seen.insert(targets[i])
      i += 1
      scanned += 1
    }
    return seen.map { entries[Int($0)] }
      .sorted { $0.count > $1.count }
      .prefix(limit)
      .map { $0 }
  }

  /// Underscores become spaces, except in emoticon tags like ^_^ where they are the point.
  static func display(_ name: String) -> String {
    name.contains(where: \.isLetter) ? name.replacingOccurrences(of: "_", with: " ") : name
  }

  static func short(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
    if n >= 1_000 { return "\(n / 1_000)k" }
    return "\(n)"
  }
}


let t0 = Date()
let text = try! String(contentsOf: URL(fileURLWithPath: NSString(string: "~/lil-art/tags/danbooru.csv").expandingTildeInPath), encoding: .utf8)
let index = TagIndex.parse(text)
print(String(format: "разобрано тегов: %d за %.2f с", index.entries.count, Date().timeIntervalSince(t0)))
for q in ["long h", "hair", "boobs", "1gi", "smil", "red e"] {
  let t = Date()
  let hits = index.search(q, limit: 5).map { "\(TagIndex.display($0.name)) \(TagIndex.short($0.count))" }
  print(String(format: "%-8@ %.1f мс → ", q as NSString, Date().timeIntervalSince(t) * 1000) + hits.joined(separator: " · "))
}
