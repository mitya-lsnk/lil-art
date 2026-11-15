import Foundation

/// What the window remembers between launches: what can be switched or picked from a list (the
/// tab, the models, PRO, the shape and size of the frame, the sampler…). Nothing the person
/// typed is in it, and nothing may be added that was: the prompt, the seed, the numbers in the
/// fields. Those are kept only when the person saves them themselves. Nor are LoRAs: every
/// launch starts with none chosen and none switched on.
struct UIChoices: Codable, Equatable {
  static let key = "ui.choices"

  var tab = "image"
  var model = ""
  var videoModel = ""
  var pro = false
  var videoPro = false
  var aspect = ""
  var megapixels = 0.0
  var quality = ""
  var sampler = 0
  var videoSampler = 0
  var preset: String?
  var showSizePad = false
  var upscaleOn = false
  var upscaler: String?
  var upscaleFactor = 0
  var videoSizeIndex = 0

  func encoded() -> Data? { try? JSONEncoder().encode(self) }

  /// nil when there is nothing readable to restore.
  static func decode(_ data: Data?) -> UIChoices? {
    guard let data, let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    var choices = UIChoices()
    choices.tab = raw["tab"] as? String ?? choices.tab
    choices.model = raw["model"] as? String ?? ""
    choices.videoModel = raw["videoModel"] as? String ?? ""
    choices.pro = raw["pro"] as? Bool ?? false
    choices.videoPro = raw["videoPro"] as? Bool ?? false
    choices.aspect = raw["aspect"] as? String ?? ""
    choices.megapixels = (raw["megapixels"] as? NSNumber)?.doubleValue ?? 0
    choices.quality = raw["quality"] as? String ?? ""
    choices.sampler = (raw["sampler"] as? NSNumber)?.intValue ?? 0
    choices.videoSampler = (raw["videoSampler"] as? NSNumber)?.intValue ?? 0
    choices.preset = raw["preset"] as? String
    choices.showSizePad = raw["showSizePad"] as? Bool ?? false
    choices.upscaleOn = raw["upscaleOn"] as? Bool ?? false
    choices.upscaler = raw["upscaler"] as? String
    choices.upscaleFactor = (raw["upscaleFactor"] as? NSNumber)?.intValue ?? 0
    choices.videoSizeIndex = (raw["videoSizeIndex"] as? NSNumber)?.intValue ?? 0
    return choices
  }
}
