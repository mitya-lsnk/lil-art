import AVFoundation
import AppKit
import Combine
import CoreGraphics
import Darwin
import Foundation
import MediaGenerationKit
import SwiftUI
import UniformTypeIdentifiers

@available(macOS 26, *)
extension Studio {
  // MARK: editing

  func pickEditRef() {
    if let url = pickImage("выберите картинку, из которой взять лицо, костюм или стиль") {
      addEditRef(url)
    }
  }


  func pickImage(_ message: String) -> URL? {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.image]
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.message = message
    return panel.runModal() == .OK ? panel.urls.first : nil
  }


  func reference(_ url: URL, _ role: RefRole) -> Reference? {
    guard let thumb = Thumbnail.make(url) else {
      notify(
        Notice(
          title: "Картинка не открылась",
          message: "\(url.lastPathComponent) — формат, который система не читает"))
      return nil
    }
    return Reference(url: url, role: role, thumb: thumb)
  }


  func setEditSource(_ url: URL) {
    guard let picked = reference(url, .source) else { return }
    editSource = picked
    editRefs.removeAll { $0.url == url }
    // a mask belongs to the picture it was painted on, and so do the zones' boxes
    editMask = nil
    editRegions = []
    editShowResult = false
    matchAspect(to: picked.thumb)
  }


  func clearEditSource() {
    editSource = nil
    editMask = nil
    editShowResult = false
  }


  func addEditRef(_ url: URL) {
    guard !editRefs.contains(where: { $0.url == url }), editSource?.url != url,
      let picked = reference(url, .moodboard)
    else { return }
    if editRefs.count >= Self.maxEditRefs { editRefs.removeFirst() }
    editRefs.append(picked)
  }


  func removeEditRef(_ ref: Reference) { editRefs.removeAll { $0.id == ref.id } }

  /// An edit keeps the picture's shape unless told otherwise; a portrait squeezed into a
  /// square comes back with its subject cropped.
  func matchAspect(to image: NSImage) {
    guard let rep = image.representations.first, rep.pixelsHigh > 0 else { return }
    let ratio = Double(rep.pixelsWide) / Double(rep.pixelsHigh)
    guard let best = Aspect.allCases.min(by: { abs($0.ratio - ratio) < abs($1.ratio - ratio) })
    else { return }
    aspect = best
    if pro {
      let (w, h) = megapixels.size(for: best)
      proWidth = w
      proHeight = h
      widthText = String(w)
      heightText = String(h)
    }
  }


  /// A short instruction added to the prompt from a chip under the edit box.
  func addToPrompt(_ phrase: String) {
    let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.localizedCaseInsensitiveContains(phrase) else { return }
    prompt = trimmed.isEmpty ? phrase : trimmed + ", " + phrase
  }


  /// "Редактировать" on a finished picture: it goes to the edit tab as the picture to change.
  func edit(_ frame: Frame) {
    tab = .edit
    setEditSource(frame.url)
  }
}
