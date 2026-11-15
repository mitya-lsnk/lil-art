import Foundation

/// Where the lil art project lives: the engine, the models, the caches, the finished pictures,
/// the tag lists and the keys. Everything hangs from one folder, and that
/// folder is asked here and nowhere else.
///
/// `build.sh` builds the real path of the project into the program's Info.plist (`LilRoot`),
/// taken from where the script itself lies. `lilart-gen` has no Info.plist but lies in `tools/`
/// of the project, so it finds the project from its own place. Neither is stored in the
/// settings, and no shortcut in the home folder is ever needed. When both fail, because the
/// project was moved or its disk is unplugged, the studio's own folder is the guess.
enum ProjectRoot {
  static let infoKey = "LilRoot"

  static func resolve(embedded: String?, executable: URL?, home: URL, isFolder: (String) -> Bool)
    -> URL
  {
    if let embedded, !embedded.isEmpty {
      let url = URL(fileURLWithPath: embedded).standardizedFileURL
      if isFolder(url.path) { return url }
    }
    if let tools = executable?.deletingLastPathComponent(), tools.lastPathComponent == "tools" {
      let project = tools.deletingLastPathComponent().standardizedFileURL
      if isFolder(project.path) { return project }
    }
    return home.appendingPathComponent("AI dev/lil/lil-art")
  }

  static func isFolder(_ path: String) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }

  /// The names of everything inside the project, in one place.
  struct Places {
    let root: URL

    var models: URL { root.appendingPathComponent("models") }
    var engine: URL { root.appendingPathComponent("engine") }
    var engineBinary: URL { engine.appendingPathComponent("gRPCServerCLI-macOS") }
    var drawThingsCLI: URL { engine.appendingPathComponent("draw-things-cli") }
    var engineLog: URL { root.appendingPathComponent("engine.log") }
    var tools: URL { root.appendingPathComponent("tools") }
    var tags: URL { root.appendingPathComponent("tags") }
    var cache: URL { root.appendingPathComponent("cache") }
    var out: URL { root.appendingPathComponent("out") }
    var secrets: URL { root.appendingPathComponent("secrets") }
    var golden: URL { root.appendingPathComponent("golden") }
  }

  static let url = resolve(
    embedded: Bundle.main.object(forInfoDictionaryKey: infoKey) as? String,
    executable: Bundle.main.executableURL?.resolvingSymlinksInPath(),
    home: FileManager.default.homeDirectoryForCurrentUser, isFolder: isFolder)
  static let places = Places(root: url)
}
