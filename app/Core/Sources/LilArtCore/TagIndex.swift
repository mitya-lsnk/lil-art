import Foundation

/// One line in the completion list. `label` is what the list shows, `insert` is what lands
/// in the prompt, so a tag can show its popularity without that number being typed in.
struct Suggestion: Hashable {
  let insert: String
  let label: String
  let appendsComma: Bool
}

/// A tag dictionary in the tagcomplete CSV format: `name,category,count,"alias,alias"`.
/// Every tag is reachable by its full name, by any later word in it and by its aliases,
/// all folded into one sorted key list so a lookup is a binary search, not a scan.
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

    // Every match is ranked, not just the first few thousand in alphabetical order: for a
    // two-letter query like "sh" the popular tags (short_hair, shirt) sit far past that point.
    // The largest two-letter prefix holds under 8k keys, so this stays cheap per keystroke.
    var seen = Set<Int32>()
    var i = low
    while i < keys.count, keys[i].hasPrefix(query) {
      seen.insert(targets[i])
      i += 1
    }
    // equal counts fall back to dictionary order so the list does not shuffle between keystrokes
    return seen.sorted {
      let a = entries[Int($0)].count
      let b = entries[Int($1)].count
      return a != b ? a > b : $0 < $1
    }
    .prefix(limit)
    .map { entries[Int($0)] }
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
