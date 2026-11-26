import Testing
@testable import LilArtCore

@Suite struct MemoryTurnTests {
  @Test func theEngineGivesWayWhenTheLanguageModelIsOutAndTheEngineHoldsAModel() {
    #expect(MemoryTurn.engineShouldYield(llmLoaded: false, engineGB: 14, busy: false))
  }

  @Test func aLoadedLanguageModelNeedsNoRoom() {
    #expect(!MemoryTurn.engineShouldYield(llmLoaded: true, engineGB: 14, busy: false))
  }

  /// Restarting an engine that holds nothing would only cost time.
  @Test func anEmptyEngineIsLeftAlone() {
    #expect(!MemoryTurn.engineShouldYield(llmLoaded: false, engineGB: 0.4, busy: false))
  }

  @Test func aRunningGenerationIsNeverInterrupted() {
    #expect(!MemoryTurn.engineShouldYield(llmLoaded: false, engineGB: 14, busy: true))
  }

  @Test func theChosenModelCountsAsLoadedWithOrWithoutAProfileName() {
    let models = [(id: "Qwen-9B", loaded: true), (id: "gemma", loaded: false)]
    #expect(MemoryTurn.llmLoaded(wanted: "Qwen-9B", models: models))
    #expect(MemoryTurn.llmLoaded(wanted: "Qwen-9B:prompt", models: models))
    #expect(!MemoryTurn.llmLoaded(wanted: "gemma", models: models))
  }

  @Test func withNoModelChosenAnyLoadedOneCounts() {
    #expect(MemoryTurn.llmLoaded(wanted: "", models: [(id: "gemma", loaded: true)]))
    #expect(!MemoryTurn.llmLoaded(wanted: "", models: [(id: "gemma", loaded: false)]))
  }
}

@Suite struct MemoryTurnBaseIDTests {
  @Test func aProfileNamesTheSameModel() {
    #expect(MemoryTurn.baseID("qwen:hermes") == "qwen")
    #expect(MemoryTurn.baseID("qwen") == "qwen")
    #expect(MemoryTurn.baseID("") == "")
  }
}
