import AppKit

/// The picture a model's card shows: one the person chose with «сделать обложкой», kept as a
/// small JPEG in data/covers. Nothing is chosen for them.
enum Covers {
  static var folder: URL { ProjectRoot.places.root.appendingPathComponent("data/covers") }

  private static let cache = NSCache<NSString, NSImage>()

  static func url(for model: String) -> URL {
    // a file name never holds "/", but a damaged list might
    folder.appendingPathComponent(model.replacingOccurrences(of: "/", with: "_") + ".jpg")
  }

  static func image(for model: String) -> NSImage? {
    let key = model as NSString
    if let hit = cache.object(forKey: key) { return hit }
    guard let image = NSImage(contentsOf: url(for: model)) else { return nil }
    cache.setObject(image, forKey: key)
    return image
  }

  /// Saves `cgImage` scaled down to at most 640 pixels on its long side.
  @discardableResult
  static func save(_ cgImage: CGImage, for model: String) -> Bool {
    let longest = CGFloat(max(cgImage.width, cgImage.height))
    let scale = min(1, 640 / max(1, longest))
    let w = max(1, Int(CGFloat(cgImage.width) * scale)), h = max(1, Int(CGFloat(cgImage.height) * scale))
    guard
      let context = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return false }
    context.interpolationQuality = .high
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let small = context.makeImage() else { return false }
    let rep = NSBitmapImageRep(cgImage: small)
    guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return false }
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    guard (try? data.write(to: url(for: model), options: .atomic)) != nil else { return false }
    cache.removeObject(forKey: model as NSString)
    return true
  }

  static func remove(for model: String) {
    try? FileManager.default.removeItem(at: url(for: model))
    cache.removeObject(forKey: model as NSString)
  }
}

@available(macOS 26, *)
extension Studio {
  func makeCover(_ frame: Frame) {
    guard !frame.modelFile.isEmpty,
      let cg = frame.image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else { return }
    if Covers.save(cg, for: frame.modelFile) { coverStamp += 1 }
  }

  func makeCover(_ clip: Clip) {
    guard !clip.modelFile.isEmpty,
      let cg = clip.poster.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else { return }
    if Covers.save(cg, for: clip.modelFile) { coverStamp += 1 }
  }

  func removeCover(_ model: String) {
    Covers.remove(for: model)
    coverStamp += 1
  }
}
