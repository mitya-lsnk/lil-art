import Foundation
#if canImport(LilKitShared)
  // LilStore is internal to the shared file: this package is only ever built to be tested.
  // In the app the shared file lies in the same module, so no import is needed there.
  @testable import LilKitShared
#endif

/// Where the models live, and where the ones moved off the Mac go.
///
/// The engine reads one folder. A model moved to an external disk is copied there and its place
/// in that folder taken by a link to the copy, so the engine finds it as before for as long as
/// the disk is plugged in; unplugged, the link points nowhere and the model is simply absent.
/// The whole folder can live elsewhere too (settings), the links work the same from there.
enum ModelsFolder {
  /// lil art's own settings: the file `data/settings.json` in the project (see LilStore).
  static var store: LilStore { LilStore.standard }

  /// The folder the person chose, or `models` inside the project.
  static func resolve(stored: String?, root: URL) -> URL {
    if let stored, !stored.isEmpty { return URL(fileURLWithPath: stored) }
    return ProjectRoot.Places(root: root).models
  }

  static var url: URL {
    resolve(stored: store.string(forKey: "models.folder"), root: ProjectRoot.url)
  }

  static func setURL(_ url: URL?) {
    store.set(url?.standardizedFileURL.path, forKey: "models.folder")
  }

  /// The folder on an external disk that models are moved to.
  static var external: URL? {
    store.string(forKey: "models.external").map { URL(fileURLWithPath: $0) }
  }

  static func setExternal(_ url: URL?) {
    store.set(url?.standardizedFileURL.path, forKey: "models.external")
  }

  /// What to tell the person while the models folder cannot be used: it lies on a disk that is
  /// not plugged in. Meanwhile nothing is made there and nothing is fetched, so the models are
  /// all still there when the disk is back. nil when the folder is fine.
  static func unavailableMessage(_ folder: URL, reachable: (URL) -> Bool = isReachable) -> String? {
    guard !reachable(folder) else { return nil }
    let disk = volumeName(of: folder) ?? folder.path
    return "Диск «\(disk)» с моделями не подключён. Подключите его и запустите движок снова: "
      + "модели на нём целы, заново ничего не скачивается"
  }

  /// "/Volumes/T7/…" belongs to the disk T7; anything else is on the Mac.
  static func volumeName(of url: URL) -> String? {
    let parts = url.standardizedFileURL.pathComponents
    guard parts.count > 2, parts[1] == "Volumes" else { return nil }
    return parts[2]
  }

  /// Whether the disk a path is on is plugged in. A path on the Mac always is. A missing disk
  /// must never have its folder made: under /Volumes that would be a fake folder on the Mac.
  static func isReachable(_ url: URL) -> Bool {
    guard let volume = volumeName(of: url) else { return true }
    let mount = URL(fileURLWithPath: "/Volumes").appendingPathComponent(volume)
    return (try? mount.resourceValues(forKeys: [.isVolumeKey]))?.isVolume == true
  }
}

/// Moves model files between the folder and an external disk, leaving links behind.
enum ModelMover {
  enum Failure: Error {
    case unreachable(String)
    case noSpace(Double)
    case mismatch(String)
    case notLinked(String)
  }

  /// Where a link in the folder points, if it is one.
  static func linkTarget(_ url: URL) -> URL? {
    guard let path = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else {
      return nil
    }
    return URL(fileURLWithPath: path, relativeTo: url.deletingLastPathComponent()).standardizedFileURL
  }

  /// The model's files that exist: itself and its weights file beside it.
  static func expand(_ files: [String], in dir: URL) -> [String] {
    var out: [String] = []
    for file in files {
      for name in [file, file + "-tensordata"] where !out.contains(name) {
        let url = dir.appendingPathComponent(name)
        let isLink = linkTarget(url) != nil
        if isLink || FileManager.default.fileExists(atPath: url.path) { out.append(name) }
      }
    }
    return out
  }

  private static func size(_ url: URL) -> Int64 {
    ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
  }

  /// Copies in pieces, so a 20 GB file shows its progress and can be stopped.
  static func copy(
    _ from: URL, to destination: URL, progress: (Int64) -> Void, shouldStop: () -> Bool
  ) throws {
    let partial = URL(fileURLWithPath: destination.path + ".part")
    try? FileManager.default.removeItem(at: partial)
    FileManager.default.createFile(atPath: partial.path, contents: nil)
    let reader = try FileHandle(forReadingFrom: from)
    let writer = try FileHandle(forWritingTo: partial)
    do {
      while true {
        if shouldStop() { throw CancellationError() }
        let chunk = try reader.read(upToCount: 32 << 20) ?? Data()
        if chunk.isEmpty { break }
        try writer.write(contentsOf: chunk)
        progress(Int64(chunk.count))
      }
      try reader.close()
      try writer.close()
      try? FileManager.default.removeItem(at: destination)
      try FileManager.default.moveItem(at: partial, to: destination)
    } catch {
      try? reader.close()
      try? writer.close()
      try? FileManager.default.removeItem(at: partial)
      throw error
    }
  }

  /// First half of moving out: every file copied to the disk and checked. The folder is not
  /// touched yet, so the engine may go on using the files meanwhile.
  static func copyOut(
    _ names: [String], from dir: URL, to external: URL, progress: (Double) -> Void,
    shouldStop: () -> Bool
  ) throws {
    guard ModelsFolder.isReachable(external) else {
      throw Failure.unreachable(ModelsFolder.volumeName(of: external) ?? external.path)
    }
    try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
    let sources = names.map { dir.appendingPathComponent($0) }.filter { linkTarget($0) == nil }
    let total = max(1, sources.reduce(0) { $0 + size($1) })
    if let free = try? external.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
      .volumeAvailableCapacityForImportantUsage, free < total + 200_000_000
    {
      throw Failure.noSpace(Double(total) / 1_073_741_824)
    }
    var done: Int64 = 0
    for source in sources {
      let destination = external.appendingPathComponent(source.lastPathComponent)
      // a copy left there before, whole, need not be made again
      if size(destination) == size(source), size(source) > 0 {
        done += size(source)
        progress(Double(done) / Double(total))
        continue
      }
      try copy(source, to: destination, progress: { bytes in
        done += bytes
        progress(Double(done) / Double(total))
      }, shouldStop: shouldStop)
      guard size(destination) == size(source) else { throw Failure.mismatch(source.lastPathComponent) }
    }
  }

  /// Second half: each file in the folder is replaced by a link to its copy. Quick; the engine
  /// should be paused around it.
  static func linkOut(_ names: [String], from dir: URL, to external: URL) throws {
    for name in names {
      let source = dir.appendingPathComponent(name)
      guard linkTarget(source) == nil else { continue }
      let destination = external.appendingPathComponent(name)
      guard size(destination) == size(source) else { throw Failure.mismatch(name) }
      try FileManager.default.removeItem(at: source)
      try FileManager.default.createSymbolicLink(at: source, withDestinationURL: destination)
    }
  }

  struct Return {
    let link: URL
    let target: URL
    let copy: URL
  }

  /// First half of bringing back: each link's file copied into the folder beside the link.
  static func copyBack(
    _ names: [String], to dir: URL, progress: (Double) -> Void, shouldStop: () -> Bool
  ) throws -> [Return] {
    let links = names.map { dir.appendingPathComponent($0) }.compactMap { link in
      linkTarget(link).map { (link: link, target: $0) }
    }
    for item in links where !FileManager.default.fileExists(atPath: item.target.path) {
      throw Failure.unreachable(ModelsFolder.volumeName(of: item.target) ?? item.target.path)
    }
    let total = max(1, links.reduce(0) { $0 + size($1.target) })
    if let free = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
      .volumeAvailableCapacityForImportantUsage, free < total + 1_000_000_000
    {
      throw Failure.noSpace(Double(total) / 1_073_741_824)
    }
    var done: Int64 = 0
    var out: [Return] = []
    for item in links {
      let local = URL(fileURLWithPath: item.link.path + ".back")
      try copy(item.target, to: local, progress: { bytes in
        done += bytes
        progress(Double(done) / Double(total))
      }, shouldStop: shouldStop)
      guard size(local) == size(item.target) else {
        try? FileManager.default.removeItem(at: local)
        throw Failure.mismatch(item.link.lastPathComponent)
      }
      out.append(Return(link: item.link, target: item.target, copy: local))
    }
    return out
  }

  /// Second half: the links give way to the copies, and the disk's files go.
  static func swapBack(_ items: [Return]) throws {
    for item in items {
      try FileManager.default.removeItem(at: item.link)
      try FileManager.default.moveItem(at: item.copy, to: item.link)
      try? FileManager.default.removeItem(at: item.target)
    }
  }
}
