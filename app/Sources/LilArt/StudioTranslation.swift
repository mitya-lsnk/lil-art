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
  // MARK: translation

  /// The English in the box was made from exactly the text there now, so a run sends it.
  var englishCurrent: Bool { !englishPrompt.isEmpty && englishSource == prompt }
  /// There is an English, but the Russian has changed since: a run sends the Russian.
  var englishStale: Bool { !englishPrompt.isEmpty && englishSource != prompt }

  /// The box stays on whichever side the person is looking at. Flipping it to the English
  /// on every translation (each run makes one) took the Russian away mid-typing.
  func store(english out: String, from text: String) {
    englishPrompt = out == text ? "" : out
    englishSource = text
  }


  /// A hand-corrected English is what the model reads, for as long as the Russian it was made
  /// from stays as it is.
  func editEnglish(_ text: String) {
    englishPrompt = text
  }


  /// Every zone of the tab in front whose description has no English yet for its text.
  func translateRegions() {
    let edit = tab == .edit
    let wanted = (edit ? editRegions : regions).filter {
      !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.englishSource != $0.text
    }
    for region in wanted {
      let text = region.text
      Task {
        let out = await english(for: text)
        var list = edit ? editRegions : regions
        // a box removed or retyped meanwhile keeps what it has now
        guard let i = list.firstIndex(where: { $0.id == region.id }), list[i].text == text else { return }
        list[i].english = out == text ? "" : out
        list[i].englishSource = text
        if edit { editRegions = list } else { regions = list }
      }
    }
  }


  /// One translation with a ceiling on how long it may take. The original text comes back
  /// when it fails or runs out of time.
  func english(for text: String, improve: Bool = false) async -> String {
    let out: String? = await withDeadline(improve ? 90 : (translator.engine == .local ? 60 : 15), fallback: nil) { [translator] in
      await translator.english(for: text, improve: improve)
    }
    guard let out else {
      // out of time: whatever is still waiting on the system translator is let go
      translator.abandonPending("переводчик не ответил за 15 секунд")
      return text
    }
    return TextRules.pictureNumbers(out)
  }


  /// What the model should read for `text`: the English made from exactly this text with the
  /// «Перевести» or «Улучшить» button, otherwise the text as written. Models with a Qwen
  /// encoder (Krea 2, Qwen Image, FLUX.2, Z-Image) read Russian as it is.
  func modelText(for text: String) async -> String {
    if text == englishSource, !englishPrompt.isEmpty { return englishPrompt }
    return text
  }


  /// The negative prompt needs the same treatment as the positive one; models read it in
  /// English too.
  func translateNegative() {
    let text = negative.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, !translatingNegative else { return }
    translatingNegative = true
    Task {
      let out = await english(for: text)
      if out != text, negative.trimmingCharacters(in: .whitespacesAndNewlines) == text {
        negative = out
      }
      translatingNegative = false
    }
  }
}
