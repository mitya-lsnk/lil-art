import Foundation
import Testing
@testable import LilArtCore

private func json(_ text: String) -> [String: Any] {
  try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
}

@Suite struct CivitaiParsingTests {
  @Test func modelsAndTheirVersionsAreReadAndHTMLIsStrippedFromDescriptions() {
    let models = SettingsImport.models(from: json("""
      {"items":[
        {"id":7,"name":"Fox Mix","type":"Checkpoint","modelVersions":[
          {"id":70,"name":"v2","baseModel":"Flux.1 D","description":"<p>Use <b>CFG 3</b></p><p>&amp; 20 steps</p>"},
          {"name":"no id"}]},
        {"name":"no id model"}]}
      """))
    #expect(models.count == 1)
    #expect(models[0].name == "Fox Mix")
    #expect(models[0].versions.count == 1)
    #expect(models[0].versions[0].baseModel == "Flux.1 D")
    #expect(models[0].versions[0].description == "Use CFG 3\n& 20 steps")
  }

  @Test func anEmptyAnswerGivesNoModels() {
    #expect(SettingsImport.models(from: [:]).isEmpty)
  }

  /// The settings sit right in "meta" in a model's list, but one level deeper when one picture is asked for.
  @Test func statsCountSamplersAndSizesAndKeepTheFirstExample() throws {
    let stats = SettingsImport.stats(from: json("""
      {"items":[
        {"meta":{"prompt":"a","steps":20,"cfgScale":7,"sampler":"Euler a","Size":"512x768","clipSkip":2}},
        {"meta":{"meta":{"prompt":"b","steps":30,"cfgScale":5,"sampler":"Euler a","Size":"512x768"}}},
        {"meta":{"prompt":"c","steps":25,"sampler":"DPM++ 2M","Size":"1024x1024","Clip skip":"1"}},
        {"meta":{"unrelated":true}},
        {"nometa":1}]}
      """))
    #expect(stats.samples == 3)
    #expect(stats.samplers.first?.name == "Euler a")
    #expect(stats.samplers.first?.count == 2)
    #expect(stats.sizes.first?.size == "512x768")
    #expect(stats.steps == [20, 30, 25])
    #expect(stats.cfgs == [7, 5])
    #expect(stats.clipSkips == [2, 1])
    #expect(stats.example?.prompt == "a")
    #expect(SettingsImport.CivitaiStats.median(stats.steps) == 25)
  }

  @Test func aSinglePictureAnswerIsReadFromTheNestedMeta() throws {
    let found = try #require(SettingsImport.image(from: json("""
      {"items":[{"meta":{"meta":{"prompt":"a fox","negativePrompt":"ugly","steps":16,"cfgScale":1,"sampler":"Euler","seed":5,"Size":"1024x768","Model":"m","clipSkip":2,"Denoising strength":"0.5"}}}]}
      """)))
    #expect(found.prompt == "a fox")
    #expect(found.negative == "ugly")
    #expect(found.steps == 16 && found.cfg == 1 && found.seed == 5)
    #expect(found.width == 1024 && found.height == 768)
    #expect(found.strength == 0.5 && found.clipSkip == 2)
    #expect(found.origin == "Civitai")
  }

  @Test func aPictureWithoutSettingsGivesNothing() {
    #expect(SettingsImport.image(from: json(#"{"items":[{"meta":{"other":1}}]}"#)) == nil)
    #expect(SettingsImport.image(from: json(#"{"items":[]}"#)) == nil)
  }
}
