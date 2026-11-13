import Foundation
import Testing
@testable import LilKitShared

private func folder() -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private func file() -> URL { folder().appendingPathComponent("data/settings.json") }

@Suite struct LilStoreTests {
  @Test func valuesComeBackFromANewStoreOnTheSameFile() {
    let path = file()
    let store = LilStore(file: path)
    store.set("studio", forKey: "lil.skin")
    store.set(true, forKey: "stage.preview")
    store.set(8, forKey: "engine.port")
    store.set(0.5, forKey: "engine.cacheGB")
    let again = LilStore(file: path)
    #expect(again.string(forKey: "lil.skin") == "studio")
    #expect(again.bool(forKey: "stage.preview") == true)
    #expect(again.integer(forKey: "engine.port") == 8)
    #expect(again.double(forKey: "engine.cacheGB") == 0.5)
  }

  @Test func whatWasNeverSetReadsAsNothingLikeUserDefaults() {
    let store = LilStore(file: file())
    #expect(store.string(forKey: "x") == nil)
    #expect(store.object(forKey: "x") == nil)
    #expect(store.bool(forKey: "x") == false)
    #expect(store.integer(forKey: "x") == 0)
    #expect(store.double(forKey: "x") == 0)
    #expect(store.dictionary(forKey: "x") == nil)
    #expect(store.stringArray(forKey: "x") == nil)
  }

  /// The app reads its tables back with casts, as it did from UserDefaults.
  @Test func tablesAndListsKeepTheirShapeAfterReloading() {
    let path = file()
    let store = LilStore(file: path)
    store.set(["krea": ["steps": 8.0, "cfg": 1.5]], forKey: "model.tweaks")
    store.set(["wan": true, "ltx": false], forKey: "model.speed")
    store.set(["a", "b"], forKey: "edit.phrases")
    let again = LilStore(file: path)
    #expect((again.dictionary(forKey: "model.tweaks") as? [String: [String: Double]])?["krea"]?["cfg"] == 1.5)
    #expect((again.dictionary(forKey: "model.speed") as? [String: Bool]) == ["wan": true, "ltx": false])
    #expect(again.stringArray(forKey: "edit.phrases") == ["a", "b"])
  }

  @Test func dataSurvivesAsDataNotAsText() {
    let path = file()
    LilStore(file: path).set(Data([0, 1, 2, 255]), forKey: "blob")
    #expect(LilStore(file: path).data(forKey: "blob") == Data([0, 1, 2, 255]))
  }

  @Test func settingNilOrRemovingForgetsTheKeyForGood() {
    let path = file()
    let store = LilStore(file: path)
    store.set("a", forKey: "one")
    store.set("b", forKey: "two")
    store.set(nil, forKey: "one")
    store.removeObject(forKey: "two")
    let again = LilStore(file: path)
    #expect(again.object(forKey: "one") == nil)
    #expect(again.object(forKey: "two") == nil)
  }

  @Test func theFileIsReadableJsonInAVisibleFolderAndNothingElseIsLeftBeside() throws {
    let path = file()
    let store = LilStore(file: path)
    store.set("studio", forKey: "lil.skin")
    store.set("dark", forKey: "lil.mode")
    let text = try String(contentsOf: path, encoding: .utf8)
    #expect(text.contains("\"lil.skin\" : \"studio\""))
    // sorted, so two writes of the same settings are the same file
    #expect(text.range(of: "lil.mode")!.lowerBound < text.range(of: "lil.skin")!.lowerBound)
    let beside = try FileManager.default.contentsOfDirectory(atPath: path.deletingLastPathComponent().path)
    #expect(beside == ["settings.json"])
  }

  /// Never lose what is there: a file that cannot be read is put aside, not written over.
  @Test func aBrokenFileIsKeptAsideAndTheStoreStartsEmpty() throws {
    let path = file()
    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "{ not json".write(to: path, atomically: true, encoding: .utf8)
    let store = LilStore(file: path)
    #expect(store.object(forKey: "anything") == nil)
    let kept = path.appendingPathExtension("broken")
    #expect((try? String(contentsOf: kept, encoding: .utf8)) == "{ not json")
    store.set("fresh", forKey: "k")
    #expect(LilStore(file: path).string(forKey: "k") == "fresh")
  }

  @Test func theStoreKeepsWorkingFromManyThreads() async {
    let path = file()
    let store = LilStore(file: path)
    await withTaskGroup(of: Void.self) { group in
      for i in 0..<40 { group.addTask { store.set(i, forKey: "k\(i)") } }
    }
    let again = LilStore(file: path)
    #expect((0..<40).allSatisfy { again.integer(forKey: "k\($0)") == $0 })
  }
}

@Suite struct LilStoreMigrationTests {
  private let legacy: [String: Any] = [
    "llm.runtime": "omlx", "engine.cacheGB": 8.0, "model.speed": ["wan": true],
    "NSWindow Frame LilArt": "10 10 800 600", "NSNavPanelExpandedSizeForOpenMode": "{800, 600}",
    "AppleLanguages": ["ru"], "com.apple.something": 1, "com_apple_SwiftUI_Settings_selectedTabIndex": 2,
    "AVDesktopPlaybackControlsControllerShowsDurationInsteadOfTimeRemainingDefaultsKey": true,
    "civitai.apiKey": "SECRET", "some.token": "SECRET", "Password": "SECRET",
  ]

  @Test func ourSettingsAreCopiedAndTheSystemsAndSecretsAreNot() {
    let kept = LilStore.migratable(legacy)
    #expect(Set(kept.keys) == ["llm.runtime", "engine.cacheGB", "model.speed"])
  }

  @Test func theFirstRunCopiesEverythingOfOursIntoTheFile() {
    let path = file()
    let store = LilStore(file: path, migratingFrom: legacy)
    #expect(store.string(forKey: "llm.runtime") == "omlx")
    #expect(store.double(forKey: "engine.cacheGB") == 8)
    #expect(store.object(forKey: "NSWindow Frame LilArt") == nil)
    // and it is on disk, not only in memory
    #expect(LilStore(file: path).string(forKey: "llm.runtime") == "omlx")
  }

  /// The second launch must not bring back old values over what was chosen since.
  @Test func aLaterRunNeverOverwritesWhatIsAlreadyInTheFile() {
    let path = file()
    let first = LilStore(file: path, migratingFrom: legacy)
    first.set("lmstudio", forKey: "llm.runtime")
    let later = LilStore(file: path, migratingFrom: legacy)
    #expect(later.string(forKey: "llm.runtime") == "lmstudio")
  }

  @Test func aKeyRemovedLaterDoesNotComeBackFromTheOldSettings() {
    let path = file()
    LilStore(file: path, migratingFrom: legacy).removeObject(forKey: "engine.cacheGB")
    #expect(LilStore(file: path, migratingFrom: legacy).object(forKey: "engine.cacheGB") == nil)
  }

  @Test func withNothingToCopyTheFileIsStillMadeSoItIsNotTriedAgain() {
    let path = file()
    _ = LilStore(file: path, migratingFrom: [:])
    #expect(FileManager.default.fileExists(atPath: path.path))
  }
}

@Suite struct LilStorePlacesTests {
  @Test func theFileLivesInDataInsideTheProject() {
    let root = URL(fileURLWithPath: "/Volumes/T7/lil-art")
    #expect(LilStore.fileURL(root: root).path == "/Volumes/T7/lil-art/data/settings.json")
    #expect(LilStore.cacheFolder(root: root).path == "/Volumes/T7/lil-art/data/cache")
  }

  @Test func theRootTheBuildPutIntoInfoPlistIsUsedOnlyWhenItIsAFolder() {
    #expect(LilStore.rootFromInfo("/p/lil-art", isFolder: { $0 == "/p/lil-art" })?.path == "/p/lil-art")
    #expect(LilStore.rootFromInfo("/p/lil-art", isFolder: { _ in false }) == nil)
    #expect(LilStore.rootFromInfo("", isFolder: { _ in true }) == nil)
    #expect(LilStore.rootFromInfo(nil, isFolder: { _ in true }) == nil)
  }
}
