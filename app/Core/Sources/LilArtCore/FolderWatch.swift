import Foundation

/// Size and modification date of a file at one moment. A file with the same stamp is the
/// same file; anything else means someone wrote to it since.
struct FileStamp: Equatable {
  let size: Int64
  let modified: Date?
}

/// What the models folder remembers between two looks at it, and what each file in it calls for.
/// A file is not imported the moment it appears: it may still be copying in.
struct FolderWatch {
  /// File sizes at the previous look: a file still being copied grows between two looks.
  var seenSizes: [String: Int64] = [:]
  /// Sources the user cancelled. Without this the next scan finds the file still lying there
  /// and queues it again at once.
  var cancelled: [String: FileStamp] = [:]
  /// When an empty file was first noticed, so that waiting for its copy to start has an end.
  var emptySince: [String: Date] = [:]

  /// The seconds an empty file is given before the folder stops looking at it.
  static let emptyGrace: TimeInterval = 30

  enum Link { case none, reachable, broken }

  enum Verdict: Equatable {
    /// A moved model whose disk is unplugged: listed as away, never read.
    case away
    /// An engine file: a model for the list.
    case model
    /// A linked file that is not the engine's: not ours to import.
    case foreignLink
    /// Empty, within the grace: look again soon.
    case emptyWaiting
    /// Empty for longer than the grace: stop looking.
    case emptyGaveUp
    case cancelledByUser
    /// Its size did not change since the last look: ready to import.
    case incoming
    /// Its size changed since the last look: look again soon.
    case growing

    /// The folder should be looked at again in a moment.
    var needsAnotherLook: Bool { self == .emptyWaiting || self == .growing }
  }

  mutating func look(
    path: String, ext: String, link: Link, isEngineFormat: () -> Bool, stamp: FileStamp?, now: Date
  ) -> Verdict {
    if link == .broken { return .away }
    let size = stamp?.size ?? 0
    if ext == "ckpt", isEngineFormat() { return .model }
    if link == .reachable { return .foreignLink }
    if size == 0 {
      // Empty is either a copy that has not started or junk. Give a copy a little time, then
      // stop looking: otherwise the library rescans every 2 s for as long as the file lies there.
      let since = emptySince[path] ?? now
      emptySince[path] = since
      return now.timeIntervalSince(since) < Self.emptyGrace ? .emptyWaiting : .emptyGaveUp
    }
    if let stamp, cancelled[path] == stamp { return .cancelledByUser }
    emptySince[path] = nil
    cancelled[path] = nil
    let stable = seenSizes[path] == size
    seenSizes[path] = size
    return stable ? .incoming : .growing
  }

  /// Forget files that left the folder, so a new file with an old name starts from scratch.
  mutating func forget(except present: Set<String>) {
    seenSizes = seenSizes.filter { present.contains($0.key) }
    emptySince = emptySince.filter { present.contains($0.key) }
    cancelled = cancelled.filter { present.contains($0.key) }
  }
}
