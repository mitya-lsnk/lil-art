import CoreGraphics
import Foundation
import ImageIO

/// One box of a layout prompt: where something goes in the picture and what it is.
///
/// FLUX.3 [klein] reads a layout from the prompt itself: the caption names each element as
/// `<region_1>`, and a JSON list after it gives every element a box and a description. Boxes
/// steer placement and scale; they are not a mask, so an element may spill over its edges.
/// In an edit the box has two places, where the element is in the picture (`source`) and
/// where it should end up (`box`); the same box twice keeps it where it is.
struct Region: Identifiable, Equatable {
  let id = UUID()
  var number: Int
  /// Where it goes, 0…1 of the picture, y down.
  var box: CGRect
  /// Edit only: where it is in the picture now.
  var source: CGRect
  var text = ""
  var english = ""
  /// The text `english` was made from; a later change of `text` makes the English stale.
  var englishSource = ""

  var label: String { "region_\(number)" }
  var moved: Bool { source != box }

  /// What the model reads: the English made from exactly this text, else the text itself
  /// (the model's Qwen encoder reads Russian too).
  var modelText: String {
    let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return !english.isEmpty && englishSource == text ? english : typed
  }
}

enum RegionLayout {
  /// Only FLUX.3 [klein] was taught this format; any other model would read the JSON as words.
  static func supports(family: String) -> Bool { family.hasPrefix("flux3") }

  /// The prompt with the layout after it. The caption must name every box; boxes it does not
  /// name are named at its end.
  static func prompt(caption: String, regions: [Region], edit: Bool) -> String {
    let used = regions.filter { !$0.modelText.isEmpty }
    guard !used.isEmpty else { return caption }
    var text = caption.trimmingCharacters(in: .whitespacesAndNewlines)
    if edit, !text.contains("<ref_image_0>") {
      text = "In <ref_image_0>, " + text
    }
    let missing = used.filter { !text.contains("<\($0.label)>") }.map { "<\($0.label)>" }
    if !missing.isEmpty {
      if !text.isEmpty, !".!?".contains(text.last!) { text += "." }
      text += (text.isEmpty ? "" : " ") + (edit ? "Elements: " : "With ")
        + missing.joined(separator: ", ") + "."
    }
    let items = used.map { region -> String in
      var fields = ["\"id\": \(quoted(region.label))"]
      if edit {
        fields.append("\"from\": \"ref_image_0\"")
        fields.append("\"src_bbox\": \(bbox(region.source))")
        fields.append("\"tgt_bbox\": \(bbox(region.box))")
      } else {
        fields.append("\"bbox\": \(bbox(region.box))")
      }
      fields.append("\"desc\": \(quoted(region.modelText))")
      return "{" + fields.joined(separator: ", ") + "}"
    }
    return text + " [" + items.joined(separator: ", ") + "]"
  }

  /// [y_min, x_min, y_max, x_max] on 0…1000: y first, the order the model was taught.
  private static func bbox(_ r: CGRect) -> String {
    let v = [r.minY, r.minX, r.maxY, r.maxX].map { Int((min(1, max(0, $0)) * 1000).rounded()) }
    return "[\(v.map(String.init).joined(separator: ", "))]"
  }

  private static func quoted(_ s: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes]),
      let array = String(data: data, encoding: .utf8)
    else { return "\"\"" }
    return String(array.dropFirst().dropLast())
  }

  private static var sizes: [URL: CGSize] = [:]

  /// A picture's pixel size from its header, without decoding it.
  static func pixelSize(_ url: URL) -> CGSize? {
    if let known = sizes[url] { return known }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      var w = props[kCGImagePropertyPixelWidth] as? CGFloat,
      var h = props[kCGImagePropertyPixelHeight] as? CGFloat
    else { return nil }
    // orientations 5…8 are turned a quarter, so the picture shows the other way round
    if let o = props[kCGImagePropertyOrientation] as? Int, o >= 5 { swap(&w, &h) }
    let size = CGSize(width: w, height: h)
    sizes[url] = size
    return size
  }
}
