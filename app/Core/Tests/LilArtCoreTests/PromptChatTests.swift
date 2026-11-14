import Foundation
import Testing
@testable import LilArtCore

@Suite struct PromptChatTests {
  @Test func aPlainRequestIsTwoTextMessages() {
    let messages = PromptChat.messages(system: "S", user: "a cat", imageJPEG: nil)
    #expect(messages.count == 2)
    #expect(messages[0]["role"] as? String == "system")
    #expect(messages[1]["content"] as? String == "a cat")
  }

  /// With a picture the user's turn carries the text and the picture, the way OpenAI-style servers take it.
  @Test func aPictureRidesInTheUsersTurnAsADataAddress() throws {
    let messages = PromptChat.messages(system: "S", user: "the dog runs", imageJPEG: Data([1, 2, 3]))
    let parts = try #require(messages[1]["content"] as? [[String: Any]])
    #expect(parts.count == 2)
    #expect(parts[0]["type"] as? String == "text")
    #expect(parts[0]["text"] as? String == "the dog runs")
    #expect(parts[1]["type"] as? String == "image_url")
    let address = (parts[1]["image_url"] as? [String: String])?["url"]
    #expect(address == "data:image/jpeg;base64,AQID")
  }

  @Test func theWholeRequestIsValidJson() {
    let messages = PromptChat.messages(system: "S", user: "u", imageJPEG: Data([0, 255]))
    #expect(JSONSerialization.isValidJSONObject(["messages": messages]))
  }

  /// The frame already shows what is there; the prompt must say what happens next.
  @Test func withAFirstFrameTheModelIsToldToDescribeMotionNotThePicture() {
    #expect(PromptChat.instructions(hasFrame: true).contains("first frame"))
    #expect(PromptChat.instructions(hasFrame: true).contains("motion"))
    #expect(!PromptChat.instructions(hasFrame: false).contains("first frame"))
  }
}
