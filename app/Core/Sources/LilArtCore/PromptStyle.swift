import Foundation

/// What kind of picture the prompt is for, so the translator and the improver choose words that
/// fit it: a furry character keeps paws and a muzzle, a photo gets a lens and no "illustration".
/// «авто» reads it off the prompt's own words; any other choice is taken as said.
enum PromptStyle: String, CaseIterable, Codable {
  case auto, none, photo, anime, furry, render3d

  init(saved: String?) { self = saved.flatMap(PromptStyle.init(rawValue:)) ?? .auto }

  var label: String {
    switch self {
    case .auto: return "авто"
    case .none: return "без"
    case .photo: return "фото"
    case .anime: return "аниме"
    case .furry: return "фурри"
    case .render3d: return "3D"
    }
  }

  var menuTitle: String {
    switch self {
    case .auto: return "Авто: по словам в промпте"
    case .none: return "Без стиля"
    case .photo: return "Фото, реализм"
    case .anime: return "Аниме"
    case .furry: return "Фурри, антро"
    case .render3d: return "3D"
    }
  }

  /// The styles to tell the model about, in a fixed order.
  func resolved(for prompt: String) -> [PromptStyle] {
    switch self {
    case .auto: return Self.detect(in: prompt)
    case .none: return []
    default: return [self]
    }
  }

  /// One paragraph for the model, nil when there is no style to speak of.
  func hint(for prompt: String) -> String? {
    let styles = resolved(for: prompt)
    guard !styles.isEmpty else { return nil }
    return styles.compactMap(\.sentence).joined(separator: " ")
  }

  private var sentence: String? {
    switch self {
    case .auto, .none:
      return nil
    case .photo:
      return "The picture is a photograph. Use photographic words: camera, lens, focal length, "
        + "aperture, real skin and material texture, the light setup. Never call it a painting, "
        + "an illustration, a render or anime."
    case .anime:
      return "The picture is anime art. Use anime illustration words: line art, cel shading, "
        + "clean flat colours, expressive eyes, an anime background. Never call it a photo or realistic."
    case .furry:
      return "The picture is furry art: the characters are anthro (anthropomorphic animals). Keep "
        + "them anthro, with fur, muzzle, tail, paws and ears that fit the species; never turn them "
        + "into humans or into plain animals. Body words go to the animal form: paws, muzzle, fur."
    case .render3d:
      return "The picture is a 3D render. Use 3D words: render engine, global illumination, "
        + "subsurface scattering, materials and shaders, depth of field. Never call it a photo or a drawing."
    }
  }

  // MARK: reading the prompt

  /// Words that name a style outright, and stems for words whose endings change.
  private static let words: [PromptStyle: (exact: Set<String>, stems: [String])] = [
    .furry: (
      ["фурри", "фури", "антро", "furry", "furries", "fursona", "anthro", "e621", "кемоно", "kemono"],
      ["антропоморф", "anthropomorph", "фурсон"]
    ),
    .anime: (
      ["аниме", "anime", "манга", "manga", "чиби", "chibi", "danbooru", "ghibli", "гибли"],
      ["анимешн", "мультяшн"]
    ),
    .render3d: (
      ["3d", "3д", "cgi", "blender", "octane", "pixar", "unreal", "c4d"],
      ["рендер", "render", "трёхмерн", "трехмерн"]
    ),
    .photo: (
      ["фото", "photo", "photos", "dslr", "реализм", "realism", "realistic", "реальный"],
      ["фотограф", "фотореал", "photograph", "photoreal", "реалистич", "съёмк", "съемк", "снимок", "hyperreal"]
    ),
  ]

  private static let order: [PromptStyle] = [.furry, .anime, .render3d, .photo]

  static func detect(in prompt: String) -> [PromptStyle] {
    let tokens = prompt.lowercased()
      .split { !($0.isLetter || $0.isNumber) }
      .map(String.init)
    return order.filter { style in
      guard let set = words[style] else { return false }
      return tokens.contains { token in
        set.exact.contains(token) || set.stems.contains { token.hasPrefix($0) }
      }
    }
  }
}
