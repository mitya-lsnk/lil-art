import Foundation

/// What each kind of ControlNet reads and how it is called on screen.
enum ControlHints {
  enum Input: Equatable {
    /// The engine makes it from the picture being edited.
    case source
    /// From the extra pictures (moodboard).
    case references
    /// A ready picture of this hint kind, given by the person.
    case picture(String)
    /// A depth map: made by the engine from the picture if its depth model is on disk,
    /// otherwise a ready one is needed.
    case depth
  }

  /// The union kind reads any of these; the person picks one.
  static let unionHints = ["canny", "depth", "pose", "tile", "blur", "gray", "lowquality"]

  private static let fromSource: Set<String> = [
    "canny", "softedge", "mlsd", "tile", "blur", "gray", "lowquality", "inpaint", "ip2p",
  ]

  static func input(for hint: String) -> Input {
    if fromSource.contains(hint) { return .source }
    switch hint {
    case "shuffle": return .references
    case "depth": return .depth
    case "pose": return .picture("pose")
    case "scribble": return .picture("scribble")
    case "color": return .picture("color")
    default: return .picture("custom")
    }
  }

  private static let names: [String: String] = [
    "canny": "контуры", "depth": "глубина", "pose": "поза", "scribble": "набросок",
    "lineart": "линии", "softedge": "мягкие края", "normalbae": "нормали", "seg": "сегменты",
    "mlsd": "прямые линии", "tile": "тайл (детали)", "blur": "из размытого",
    "gray": "раскрасить ч/б", "lowquality": "из плохого качества", "inpaint": "инпейнт",
    "ip2p": "инструкция", "shuffle": "стиль с картинки", "color": "цветовая карта",
  ]

  static func label(for hint: String) -> String { names[hint] ?? hint }
}
