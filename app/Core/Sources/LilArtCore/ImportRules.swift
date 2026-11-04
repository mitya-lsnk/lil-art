import Foundation

/// The decisions inside an import that need no files and no engine, so they can be tested.
enum ImportRules {
  /// An 8-bit download leaves the importer at 16 bits, twice its size.
  static func cameOutWiderThanItWent(importedBytes: Int64, sourceBytes: Int64) -> Bool {
    Double(importedBytes) > Double(sourceBytes) * 1.5
  }

  /// A compressed file under this size means something was cut short: half of what the plan
  /// should give, and never less than ten megabytes.
  static func smallestPlausibleBytes(inputBytes: Int64, bits: Int) -> Int64 {
    max(10_000_000, Int64(Double(inputBytes) * Double(max(3, bits)) / 16 * 0.5))
  }

  /// The importer's warning (a companion download failed) as a note, nil when there was none.
  static func warningNote(_ warning: String) -> String? {
    let text = warning.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    let detail = text.split(whereSeparator: \.isNewline).prefix(2).joined(separator: "; ")
    return "не докачались нужные модели файлы, без интернета она может не запуститься ("
      + String(detail.prefix(240)) + ")"
  }

  /// The importer leaves Wan's picture-to-video models marked text-to-video ("none"); their
  /// 36 input channels (noise, mask, picture) say otherwise, and without the mark the engine
  /// ignores the first frame.
  static func needsPictureMark(version: String, modifier: String, channels: Int?) -> Bool {
    version.hasPrefix("wan") && (modifier.isEmpty || modifier == "none") && channels == 36
  }

  enum Rollback: Equatable {
    case keepEverything
    case putOldCopyBack
    case removeWhatThisRunWrote
    case leaveAlone
  }

  /// What a failed import does to the models folder. A finished model stays; a copy set aside
  /// comes back; a model that did not exist before loses what this run wrote.
  static func rollback(imported: Bool, setAside: Bool, existedBefore: Bool) -> Rollback {
    if imported { return .keepEverything }
    if setAside { return .putOldCopyBack }
    return existedBefore ? .leaveAlone : .removeWhatThisRunWrote
  }

  static func joined(_ note: String?, _ more: String) -> String {
    note.map { $0 + "; " + more } ?? more
  }
}
