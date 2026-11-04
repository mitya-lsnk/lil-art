import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// A picture dropped from anywhere: Finder hands over a file, but a browser hands over the
/// picture's bytes, a promise of a file, or only its web address. All of them end up as a file
/// on disk, so the rest of the app only ever deals with files.
struct DroppedPicture: Transferable {
  let fileURL: URL?

  static var folder: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("lil-art/cache/dropped")
  }

  private static func keep(_ data: Data, ext: String) throws -> URL {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent(UUID().uuidString + "." + ext)
    try data.write(to: url, options: .atomic)
    return url
  }

  /// A web address: fetched, and kept only if it really is a picture.
  static func download(_ url: URL) async throws -> URL {
    var request = URLRequest(url: url, timeoutInterval: 30)
    // some image hosts refuse requests that do not look like a browser's
    request.setValue("Mozilla/5.0 (Macintosh) lil art", forHTTPHeaderField: "User-Agent")
    let (data, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false,
      let type = (response.mimeType.flatMap { UTType(mimeType: $0) }) ?? UTType(
        filenameExtension: url.pathExtension),
      type.conforms(to: .image)
    else { throw URLError(.cannotDecodeContentData) }
    return try keep(data, ext: type.preferredFilenameExtension ?? "png")
  }

  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(importedContentType: .image) { received in
      // the system takes its copy away after this returns
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let copy = folder.appendingPathComponent(
        UUID().uuidString + "." + (received.file.pathExtension.isEmpty ? "png" : received.file.pathExtension))
      try FileManager.default.copyItem(at: received.file, to: copy)
      return DroppedPicture(fileURL: copy)
    }
    DataRepresentation(importedContentType: .image) { data in
      DroppedPicture(fileURL: try keep(data, ext: "png"))
    }
    ProxyRepresentation(importing: { (url: URL) in
      if url.isFileURL {
        let isPicture = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
        return DroppedPicture(fileURL: isPicture ? url : nil)
      }
      return DroppedPicture(fileURL: try await download(url))
    })
  }
}
