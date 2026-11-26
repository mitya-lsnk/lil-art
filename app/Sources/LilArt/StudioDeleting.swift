import AppKit

/// Deleting a result from inside the program: the file goes for good, not to the Trash, and
/// every list that showed it lets go of it. Asked once per deletion, unless the person ticked
/// «больше не спрашивать» (a switch, so it is kept).
@available(macOS 26, *)
extension Studio {
  static let deleteNoAskKey = "results.deleteNoAsk"

  /// True when the person agreed (or asked not to be asked again).
  private func confirmDelete(_ what: String, _ url: URL) -> Bool {
    if LilStore.standard.bool(forKey: Self.deleteNoAskKey) { return true }
    let alert = NSAlert()
    alert.messageText = "Удалить \(what) насовсем?"
    alert.informativeText = "\(url.lastPathComponent) будет стёрт с диска, не в Корзину. Вернуть его будет нельзя."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Удалить")
    alert.addButton(withTitle: "Отмена")
    alert.buttons.first?.hasDestructiveAction = true
    alert.showsSuppressionButton = true
    alert.suppressionButton?.title = "Больше не спрашивать"
    guard alert.runModal() == .alertFirstButtonReturn else { return false }
    if alert.suppressionButton?.state == .on { LilStore.standard.set(true, forKey: Self.deleteNoAskKey) }
    return true
  }

  private func erase(_ url: URL) -> Bool {
    do {
      try FileManager.default.removeItem(at: url)
      return true
    } catch {
      notify(Notice(title: "Не удалилось", message: Self.capitalized(error.localizedDescription), actions: []))
      return false
    }
  }

  /// The seed of a picture becomes the one every next run starts from, until the program is
  /// closed (the seed is never saved); pressed again on the same picture, it lets go.
  func keepSeed(_ seed: UInt32) {
    if seedLocked, lockedSeed == seed {
      seedLocked = false
      status = "Seed снова случайный"
    } else {
      lockedSeed = seed
      seedLocked = true
      status = "Seed \(seed) закреплён"
    }
  }

  func delete(_ frame: Frame) {
    guard confirmDelete("картинку", frame.url), erase(frame.url) else { return }
    forgetPicture(frame.url)
  }

  /// A picture known only by its file (the strip of recent pictures on the video tab).
  func deletePicture(at url: URL) {
    guard confirmDelete("картинку", url), erase(url) else { return }
    forgetPicture(url)
  }

  private func forgetPicture(_ url: URL) {
    let index = frames.firstIndex { $0.url == url }
    frames.removeAll { $0.url == url }
    batchGroup.removeAll { $0.url == url }
    recentStills.removeAll { $0.url == url }
    if fullscreen?.url == url { fullscreen = nil }
    if editResult?.url == url {
      editResult = nil
      editShowResult = false
    }
    if selected?.url == url {
      // the neighbour takes its place, so the stage does not go blank
      selected = index.flatMap { frames.indices.contains($0) ? frames[$0] : frames.last }
    }
    if batchGroup.count < 2 { gridMode = false }
  }

  func delete(_ clip: Clip) {
    guard confirmDelete("видео", clip.url) else { return }
    let index = clips.firstIndex { $0.id == clip.id }
    if selectedClip?.id == clip.id {
      // the player lets go of the file before it is erased
      clipLooper?.disableLooping()
      clipPlayer.removeAllItems()
      clipLooper = nil
      selectedClip = nil
    }
    guard erase(clip.url) else { return }
    clips.removeAll { $0.id == clip.id }
    if selectedClip == nil, let index {
      let next = clips.indices.contains(index) ? clips[index] : clips.last
      if let next { show(next) }
    }
  }
}
