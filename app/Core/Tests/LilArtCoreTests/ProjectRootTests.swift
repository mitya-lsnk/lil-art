import Foundation
import Testing
@testable import LilArtCore

private let home = URL(fileURLWithPath: "/Users/someone")

private func folder() -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

@Suite struct ProjectRootTests {
  private func resolve(
    embedded: String? = nil, executable: String? = nil, folders: Set<String> = []
  ) -> String {
    ProjectRoot.resolve(
      embedded: embedded, executable: executable.map { URL(fileURLWithPath: $0) }, home: home,
      isFolder: { folders.contains($0) }
    ).path
  }

  @Test func theRootTheBuildPutIntoTheProgramIsUsedWhenItIsAFolder() {
    #expect(resolve(embedded: "/Volumes/T7/lil-art", folders: ["/Volumes/T7/lil-art"]) == "/Volumes/T7/lil-art")
  }

  @Test func withNothingEmbeddedTheProjectIsWhereTheStudioKeepsIt() {
    #expect(resolve() == "/Users/someone/AI dev/lil/lil-art")
    #expect(resolve(embedded: "") == "/Users/someone/AI dev/lil/lil-art")
  }

  /// The project was moved or its disk is unplugged: the studio's folder is the honest guess.
  @Test func anEmbeddedRootThatIsNotThereAnyMoreFallsBack() {
    #expect(resolve(embedded: "/gone/lil-art") == "/Users/someone/AI dev/lil/lil-art")
  }

  @Test func anEmbeddedRootIsTidiedUp() {
    #expect(resolve(embedded: "/work/a/../lil-art/", folders: ["/work/lil-art"]) == "/work/lil-art")
  }

  /// `lilart-gen` has no Info.plist: it lies in tools/ of the project and finds it from there.
  @Test func theGeneratorFindsTheProjectFromWhereItLies() {
    #expect(
      resolve(executable: "/Volumes/T7/lil-art/tools/lilart-gen", folders: ["/Volumes/T7/lil-art"])
        == "/Volumes/T7/lil-art")
  }

  @Test func theEmbeddedRootWinsOverWhereTheProgramLies() {
    #expect(
      resolve(
        embedded: "/a/lil-art", executable: "/b/lil-art/tools/lilart-gen",
        folders: ["/a/lil-art", "/b/lil-art"]) == "/a/lil-art")
  }

  /// The app itself lies in /Applications: that says nothing about the project.
  @Test func aProgramThatDoesNotLieInToolsSaysNothingAboutTheProject() {
    #expect(
      resolve(executable: "/Applications/lil art.app/Contents/MacOS/lil art", folders: ["/Applications"])
        == "/Users/someone/AI dev/lil/lil-art")
  }

  @Test func aToolsFolderWhoseProjectIsGoneFallsBack() {
    #expect(resolve(executable: "/gone/lil-art/tools/lilart-gen") == "/Users/someone/AI dev/lil/lil-art")
  }

  @Test func everyPlaceHangsFromTheRootAndNeverFromHome() {
    let root = URL(fileURLWithPath: "/Volumes/T7/lil-art")
    let places = ProjectRoot.Places(root: root)
    let all = [
      places.models, places.engine, places.engineBinary, places.engineLog, places.drawThingsCLI,
      places.tools, places.tags, places.history, places.cache, places.out, places.secrets,
      places.golden,
    ]
    for place in all {
      #expect(place.path.hasPrefix("/Volumes/T7/lil-art/"), "\(place.path)")
    }
  }

  @Test func thePlacesKeepTheirOldNamesInsideTheRoot() {
    let places = ProjectRoot.Places(root: URL(fileURLWithPath: "/r"))
    #expect(places.models.path == "/r/models")
    #expect(places.engineBinary.path == "/r/engine/gRPCServerCLI-macOS")
    #expect(places.drawThingsCLI.path == "/r/engine/draw-things-cli")
    #expect(places.engineLog.path == "/r/engine.log")
    #expect(places.cache.path == "/r/cache")
    #expect(places.out.path == "/r/out")
    #expect(places.tags.path == "/r/tags")
    #expect(places.history.path == "/r/history.json")
    #expect(places.secrets.path == "/r/secrets")
  }
}

@Suite struct ModelsFolderChoiceTests {
  @Test func byDefaultTheModelsLiveInsideTheProject() {
    let root = URL(fileURLWithPath: "/Volumes/T7/lil-art")
    #expect(ModelsFolder.resolve(stored: nil, root: root).path == "/Volumes/T7/lil-art/models")
    #expect(ModelsFolder.resolve(stored: "", root: root).path == "/Volumes/T7/lil-art/models")
  }

  @Test func aChosenFolderWinsEvenOnAnotherDisk() {
    let root = URL(fileURLWithPath: "/Users/someone/AI dev/lil/lil-art")
    #expect(ModelsFolder.resolve(stored: "/Volumes/T7/models", root: root).path == "/Volumes/T7/models")
  }
}

@Suite struct NoPathThroughHomeTests {
  /// The old shortcut `~/lil-art` is a link the studio deletes at the end; nothing may go through it.
  @Test func noSourceOrScriptBuildsAPathFromHomeAndLilArt() throws {
    let project = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    var hits: [String] = []
    let fm = FileManager.default
    var files: [URL] = ["build.sh", "tools/GEN.md"].map { project.appendingPathComponent($0) }
    for dir in ["app/Sources", "app/Core/Sources", "tools"] {
      let base = project.appendingPathComponent(dir)
      for case let url as URL in fm.enumerator(at: base, includingPropertiesForKeys: nil) ?? NSEnumerator()
      where ["swift", "sh", "md"].contains(url.pathExtension) { files.append(url) }
    }
    #expect(files.count > 10)
    for url in files {
      let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
      for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
      where line.contains("\"lil-art/") || line.contains("\"lil-art\"") || line.contains("$HOME/lil-art")
        || line.contains("~/lil-art")
      {
        hits.append("\(url.lastPathComponent):\(n + 1)")
      }
    }
    #expect(hits.isEmpty, "\(hits)")
  }
}
