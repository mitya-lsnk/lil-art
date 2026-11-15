import Foundation
import Testing
@testable import LilArtCore
@testable import LilKitShared

private func store() -> LilStore {
  LilStore(file: FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString).appendingPathComponent("settings.json"))
}

/// The program keeps settings and the engine's technical log; it does not keep a record of what
/// the person did unless they saved it themselves.
@Suite struct RecordsTests {
  @Test func keysOfRecordsThatNothingWritesAnyMoreAreRemoved() {
    let s = store()
    s.set(false, forKey: "assist.history")
    s.set([String](), forKey: "llm.released")
    s.set("studio", forKey: "lil.skin")
    Records.purge(s, keepSession: true)
    #expect(s.object(forKey: "assist.history") == nil)
    #expect(s.object(forKey: "llm.released") == nil)
    #expect(s.string(forKey: "lil.skin") == "studio")
  }

  @Test func theLastSessionIsKeptOnlyWhenRestoringItIsOn() {
    let s = store()
    s.set(Data([1, 2, 3]), forKey: "session.last")
    Records.purge(s, keepSession: true)
    #expect(s.data(forKey: "session.last") == Data([1, 2, 3]))
    Records.purge(s, keepSession: false)
    #expect(s.object(forKey: "session.last") == nil)
  }

  @Test func settingsTheWorkIsBuiltOnSurvive() {
    let s = store()
    s.set(["m.ckpt": ["steps": 8]], forKey: "model.saved")
    s.set(["a": 1.0], forKey: "video.rate")
    s.set(["a", "b"], forKey: "edit.phrases")
    Records.purge(s, keepSession: false)
    #expect(s.object(forKey: "model.saved") != nil)
    #expect(s.object(forKey: "video.rate") != nil)
    #expect(s.stringArray(forKey: "edit.phrases") == ["a", "b"])
  }

  @Test func theOldPromptHistoryFileIsDeletedAndNothingElseBeside() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("[\"a cat\"]".utf8).write(to: root.appendingPathComponent("history.json"))
    try Data("x".utf8).write(to: root.appendingPathComponent("engine.log"))
    Records.removeOldFiles(in: root)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("history.json").path))
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("engine.log").path))
  }

  @Test func aMissingFileIsNotAnError() {
    Records.removeOldFiles(in: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)"))
  }
}
