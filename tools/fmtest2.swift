import Foundation
import FoundationModels

@main
struct T {
  static let prompts = [
    "чугунный чайник на деревянном столе, утренний свет из окна, пар",
    "рыжая лиса спит на мшистом пне, туман, рассвет в еловом лесу",
    "латунный морской конёк, макро, чёрный бархатный фон, жёсткий свет",
  ]

  static let variants: [(String, String)] = [
    ("наивная", """
      You translate image-generation prompts into English. Keep the meaning and the order \
      of the elements. Do not add anything. Reply with the translation only.
      """),
    ("строгая", """
      Translate the Russian image prompt into English, literally and completely.
      Rules:
      - Translate every noun and every adjective. Never drop a word.
      - Never replace a word with a similar-sounding one.
      - Never invent objects, people, places or moods that are not in the source.
      - Keep it a comma-separated list of visual elements, same order as the source.
      - Output only the translation. No quotes, no notes.
      Example:
      Source: медный чайник на столе, пар
      Output: copper kettle on a table, steam
      """),
  ]

  static func main() async {
    guard SystemLanguageModel.default.isAvailable else { print("модель недоступна"); return }
    for (label, instructions) in variants {
      print("=== инструкция: \(label) ===")
      for p in prompts {
        let session = LanguageModelSession(instructions: instructions)
        do {
          let r = try await session.respond(to: p)
          print("RU: \(p)")
          print("EN: \(r.content.trimmingCharacters(in: .whitespacesAndNewlines))\n")
        } catch {
          print("RU: \(p)\nошибка: \(error)\n")
        }
      }
    }
  }
}
