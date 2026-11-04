import Foundation

/// Rules for the text sent to a model, with no window and no translator in them.
enum TextRules {
  /// Words a translator must not lose, one per line: "лифчик = bra".
  static let defaultGlossary = """
    лифчик = bra
    бюстгальтер = bra
    трусик = panties/underwear
    трусы = underwear/panties/briefs
    трусах = underwear/panties/briefs
    стринг = thong
    бель = lingerie/underwear
    купальник = swimsuit/bathing suit
    бикини = bikini
    чулк = stockings
    колготк = pantyhose/tights
    корсет = corset
    подвязк = garter
    голая = nude/naked
    голый = nude/naked
    голую = nude/naked
    голые = nude/naked
    обнажённ = nude/naked
    обнажен = nude/naked
    грудь = breasts/breast/chest
    груди = breasts/breast/chest
    сосок = nipples/nipple
    соски = nipples/nipple
    ягодиц = buttocks/butt
    попа = butt/buttocks
    попк = butt/buttocks
    """

  /// Puts back every glossary word the translation lost: a Russian word that starts with an
  /// entry's left side, with none of the entry's English in the result, gets that English added
  /// at the end. Out of place, but there, which is what the picture needs.
  static func keepingTerms(of source: String, in english: String, glossary: String) -> String {
    let words = source.lowercased().replacingOccurrences(of: "ё", with: "е")
      .components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
    let lowered = english.lowercased()
    var missing: [String] = []
    for line in glossary.split(whereSeparator: \.isNewline) {
      let sides = line.split(separator: "=", maxSplits: 1).map {
        $0.trimmingCharacters(in: .whitespaces)
      }
      guard sides.count == 2, !sides[0].isEmpty, !sides[1].isEmpty else { continue }
      let stem = sides[0].lowercased().replacingOccurrences(of: "ё", with: "е")
      // "breasts/breast/chest": any of them counts, the first is what gets added
      let terms = sides[1].split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
      guard let term = terms.first, words.contains(where: { $0.hasPrefix(stem) }) else { continue }
      // "bra" is in "bracelet" and "zebra": only a whole word counts as present
      let present = terms.contains { candidate in
        lowered.range(
          of: "\\b\(NSRegularExpression.escapedPattern(for: candidate.lowercased()))\\b",
          options: .regularExpression) != nil
      }
      if !present, !missing.contains(term) { missing.append(term) }
    }
    guard !missing.isEmpty else { return english }
    let trimmed = english.trimmingCharacters(in: .whitespacesAndNewlines)
    let joiner = trimmed.hasSuffix(".") || trimmed.hasSuffix(",") ? " " : ", "
    return trimmed + joiner + missing.joined(separator: ", ")
  }

  /// Editing models tell their input pictures apart as "image 1", "image 2"… The translator
  /// renders «картинка 2» as "picture 2", "photo 2" or "pic 2"; all of them become the one
  /// wording the model was taught.
  static func pictureNumbers(_ text: String) -> String {
    var out = text
    let rules = [
      (#"\b(?:pictures|photos|photographs|pics|images|illustrations|drawings)\s+(?=[1-9]\b)"#, "images "),
      (#"\b(?:picture|photo|photograph|pic|img|image|illustration|drawing)\s*(?:no\.?\s*|#\s*)?(?=[1-9]\b)"#, "image "),
    ]
    for (pattern, replacement) in rules {
      guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
      else { continue }
      out = regex.stringByReplacingMatches(
        in: out, range: NSRange(out.startIndex..., in: out), withTemplate: replacement)
    }
    return out
  }
}
