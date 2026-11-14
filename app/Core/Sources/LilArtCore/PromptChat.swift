import Foundation

/// What is sent to the language model that improves a prompt.
enum PromptChat {
  static let plain = """
    You expand short English image prompts. Keep every subject, object and adjective the \
    author wrote, in the same order, then add concrete visual detail: lighting, materials, \
    texture, lens, mood. Never replace or remove anything the author named. Never invent a \
    different subject. Stay under 60 words. Reply with the prompt only.
    """

  /// Image-to-video: the picture is the first frame, so the prompt is about what happens next.
  static let fromFrame = """
    You write prompts for an image-to-video model. The attached picture is the first frame of \
    the clip, and the text is what the author wants to happen. Look at the picture: who and \
    what is in it, where they are, the light. Write one English prompt that describes the \
    motion that follows from this exact frame: what the subject does, how fast, how the camera \
    moves, how light and background change. Name the subject the way it looks in the frame. \
    Keep everything the author asked for. Do not describe things that are not in the frame and \
    do not contradict it. Do not re-describe the static picture in detail. Stay under 70 words. \
    Reply with the prompt only.
    """

  static func instructions(hasFrame: Bool) -> String { hasFrame ? fromFrame : plain }

  static func messages(system: String, user: String, imageJPEG: Data?) -> [[String: Any]] {
    var content: Any = user
    if let imageJPEG {
      content = [
        ["type": "text", "text": user],
        ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + imageJPEG.base64EncodedString()]],
      ] as [[String: Any]]
    }
    return [["role": "system", "content": system], ["role": "user", "content": content]]
  }
}
