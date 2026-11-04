import AppKit
let checker = NSSpellChecker.shared
let langs = checker.availableLanguages
print("языков проверки:", langs.count)
print("русский:", langs.contains { $0.hasPrefix("ru") } ? "есть" : "нет", "· английский:", langs.contains { $0.hasPrefix("en") } ? "есть" : "нет")
let text = "чугуный чайник на деревяном столе, утрений свет"
let tag = NSSpellChecker.uniqueSpellDocumentTag()
var pos = 0
var found: [String] = []
while pos < (text as NSString).length {
  let r = checker.checkSpelling(of: text, startingAt: pos, language: "ru", wrap: false, inSpellDocumentWithTag: tag, wordCount: nil)
  if r.location == NSNotFound { break }
  let word = (text as NSString).substring(with: r)
  let guess = checker.guesses(forWordRange: r, in: text, language: "ru", inSpellDocumentWithTag: tag)?.first ?? "?"
  found.append("\(word) → \(guess)")
  pos = r.location + r.length
}
print("нашёл ошибок:", found.count)
found.forEach { print("  " + $0) }
let comp = checker.completions(forPartialWordRange: NSRange(location: 0, length: 4), in: "моло", language: "ru", inSpellDocumentWithTag: tag) ?? []
print("системное автодополнение для «моло»:", comp.prefix(5).joined(separator: ", "))
