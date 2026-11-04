import Foundation
import FoundationModels

@main
struct T {
  static func main() async {
    let model = SystemLanguageModel.default
    switch model.availability {
    case .available:
      print("доступность: РАБОТАЕТ")
    case .unavailable(let reason):
      print("доступность: нет —", String(describing: reason))
      return
    }
    let cases = [
      ("перевод", """
        You translate image-generation prompts into English. Keep the meaning and the order \
        of the elements. Do not add anything. Reply with the translation only.
        """),
      ("перевод + дополнение", """
        You rewrite image-generation prompts in English. Translate the prompt, keep every \
        subject the author named, then add a little concrete visual detail: lighting, \
        materials, lens, mood. Stay under 60 words. Reply with the prompt only.
        """),
    ]
    let source = "чугунный чайник на деревянном столе, утренний свет из окна, пар"
    print("исходник: \(source)\n")
    for (label, instructions) in cases {
      let session = LanguageModelSession(instructions: instructions)
      let t0 = Date()
      do {
        let r = try await session.respond(to: source)
        print(String(format: "[%@]  %.2f с", label, Date().timeIntervalSince(t0)))
        print(r.content.trimmingCharacters(in: .whitespacesAndNewlines), "\n")
      } catch {
        print("[\(label)] ошибка: \(error)\n")
      }
    }
  }
}
