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
  // MARK: notices

  // MARK: notices

  func notify(_ notice: Notice) {
    notices.removeAll { $0.title == notice.title }
    notices.append(notice)
    if notices.count > 3 { notices.removeFirst(notices.count - 3) }
    // a notice with nothing to press only informs, so it leaves by itself
    if notice.actions.isEmpty {
      let id = notice.id
      Task { [weak self] in
        try? await Task.sleep(nanoseconds: 7_000_000_000)
        self?.notices.removeAll { $0.id == id }
      }
    }
  }


  func dismiss(_ notice: Notice) {
    notices.removeAll { $0.id == notice.id }
  }


  nonisolated static func capitalized(_ text: String) -> String {
    text.prefix(1).uppercased() + text.dropFirst()
  }


  func modelFailed(_ error: Error) -> Notice {
    Notice(
      title: "Модель не открылась",
      message: Self.capitalized(error.localizedDescription),
      actions: [.init("Перезапустить движок", .restartEngine), .init("Модели…", .openModels)])
  }


  func report(_ problem: Translator.Problem) {
    switch problem {
    case .providerFailed(let engine, let reason):
      notify(
        Notice(
          title: "\(engine.label) не перевёл",
          message: "Prompt переведён через Apple." + (reason.isEmpty ? "" : " Причина: \(reason)"),
          actions: [.init("Переводить через Apple", .useTranslator(.system))]))
    case .translationFailed:
      var actions: [Notice.Choice] = []
      if translator.engine != .google {
        actions.append(.init("Через Google", .useTranslator(.google)))
      }
      actions.append(.init("Повторить", .retryTranslation))
      notify(
        Notice(title: "Перевести не удалось", message: "Prompt остался как написан", actions: actions))
    case .enrichFailed(let reason):
      notify(
        Notice(
          title: "Улучшить не удалось",
          message: "Prompt только переведён. " + Self.capitalized(reason),
          actions: [.init("Настройки улучшения", .openSettings(.translation))]))
    }
  }


  // MARK: leafing through results

  // MARK: leafing through results

  /// ← and → go through the results in fullscreen, or while the pointer is over the picture and
  /// nothing is being typed; Esc leaves fullscreen.
  func installKeyMonitor() {
    guard keyMonitor == nil else { return }
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      MainActor.assumeIsolated {
        guard let self else { return event }
        switch event.keyCode {
        case 53 where self.fullscreen != nil:
          self.fullscreen = nil
          return nil
        case 123, 124:
          let typing = NSApp.keyWindow?.firstResponder is NSText
          guard self.fullscreen != nil || (self.stageHovered && !typing) else { return event }
          self.step(through: event.keyCode == 123 ? 1 : -1)
          return nil
        default:
          return event
        }
      }
    }
  }


  /// Newest results come first, so going left means going back in time.
  func step(through offset: Int) {
    guard !frames.isEmpty else { return }
    let current = fullscreen ?? selected
    let index = current.flatMap { frame in frames.firstIndex { $0.id == frame.id } } ?? 0
    let next = min(max(index + offset, 0), frames.count - 1)
    let frame = frames[next]
    selected = frame
    gridMode = false
    if fullscreen != nil { fullscreen = frame }
    revealHUD()
  }


  func position(of frame: Frame) -> String {
    guard let index = frames.firstIndex(where: { $0.id == frame.id }) else { return "" }
    return "\(frames.count - index) из \(frames.count)"
  }


  // MARK: overlay

  // MARK: overlay

  func revealHUD() {
    hudTask?.cancel()
    hudShown = true
    guard hudMode == .auto else {
      hudShown = hudMode == .always
      return
    }
    hudTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 300_000_000)
      guard !Task.isCancelled else { return }
      await MainActor.run { self?.hudShown = false }
    }
  }


  func hoverHUD(_ inside: Bool) {
    guard hudMode == .auto else { return }
    if inside {
      hudTask?.cancel()
      hudShown = true
    } else {
      revealHUD()
    }
  }


  func setHUDMode(_ m: HUDMode) {
    hudMode = m
    switch m {
    case .always: hudTask?.cancel(); hudShown = true
    case .never: hudTask?.cancel(); hudShown = false
    case .auto: revealHUD()
    }
  }
}
