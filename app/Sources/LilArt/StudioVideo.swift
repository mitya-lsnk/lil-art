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
  // MARK: video

  /// The engine builds its GPU programs and maps the weights on first use, which costs
  /// about half a minute once per launch. Doing it in the background right away means the
  /// first frame the user asks for is already a warm one.
  func warmUp() {
    engineHost.autoStart(modelsDir: modelsDir)
    Task { await loadClips() }
    Task { await loadStills() }
    Task { [weak self] in
      guard let self else { return }
      if let message = ModelsFolder.unavailableMessage(self.modelsDir) {
        self.status = "диск с моделями не подключён"
        self.notify(
          Notice(
            title: "Диск с моделями не подключён", message: message,
            actions: [.init("Диск подключён, запустить", .restartEngine)]))
        return
      }
      // The engine is a separate program; there is nothing to warm until it answers.
      for _ in 0..<30 {
        if self.engineHost.ready { break }
        try? await Task.sleep(nanoseconds: 700_000_000)
      }
      guard self.engineHost.ready else {
        self.status = "движок не запущен"
        return
      }
      self.status = "прогреваю движок"
      let warm = self.tab == .video && !self.videoModel.isEmpty ? self.videoModel : self.model
      do {
        let r = try await self.engine.prepare(
          model: warm, backend: self.engineHost.backend, key: self.engineKey)
        if warm == self.model { self.recommended = r }
        self.tweakDefaults[warm] = r.defaults
        if !self.busy { self.status = "готов" }
        self.refreshMemory()
      } catch {
        self.status = "движок не открылся: \(error.localizedDescription)"
        self.notify(
          Notice(
            title: "Движок не открыл модель",
            message: Self.capitalized(error.localizedDescription),
            actions: [.init("Перезапустить движок", .restartEngine), .init("Модели…", .openModels)]))
      }
    }
  }


  // MARK: video settings

  // MARK: video settings

  var videoEntry: InstalledModel? { videoModels.first(where: { $0.file == videoModel }) }
  var videoFamily: VideoFamily? { videoEntry.flatMap { VideoFamily.of($0.family) } }
  var videoSizes: [VideoSize] { videoFamily?.sizes ?? VideoFamily.wanSmall.sizes }
  var videoSize: VideoSize {
    if videoPro, let custom = videoCustomSize { return custom }
    let list = videoSizes
    return list[min(max(0, videoSizeIndex), list.count - 1)]
  }


  func setVideoCustomSize(width: Int, height: Int) {
    func snap(_ v: Int) -> Int { min(2048, max(256, Int((Double(v) / 64).rounded()) * 64)) }
    if !videoPro { videoPro = true }
    videoCustomSize = VideoSize(width: snap(width), height: snap(height), shape: "своё")
  }


  /// The first frame's own shape at about the pixels of the model's size, in 64-pixel steps.
  func fitVideoSizeToFrame() {
    guard let url = videoFirstFrame?.url,
      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let pw = props[kCGImagePropertyPixelWidth] as? Int,
      let ph = props[kCGImagePropertyPixelHeight] as? Int, pw > 0, ph > 0
    else { return }
    let base = videoSizes[min(max(0, videoSizeIndex), videoSizes.count - 1)]
    let best = SizeFit.best(
      ratio: Double(pw) / Double(ph), area: Double(base.width * base.height), maxSide: 2048)
    guard let best else { return }
    setVideoCustomSize(width: best.width, height: best.height)
    status = "размер \(best.width)×\(best.height) — по первому кадру \(pw)×\(ph)"
  }

  var videoFrames: Int {
    guard let family = videoFamily else { return 49 }
    return family.frames(forSeconds: videoSeconds, fps: videoFPS)
  }

  var videoLengthLabel: String {
    String(
      format: "%.1f с · %d кадров · %d к/с", Double(videoFrames) / Double(max(1, videoFPS)),
      videoFrames, videoFPS)
  }

  var videoFixedLength: Bool { videoFamily?.fixedFrames != nil }

  /// Whether this model animates a picture you hand it, or works from the prompt alone.
  /// Whether the video model animates a picture: what the person said, else what its
  /// description and name say.
  var videoTakesImage: Bool {
    guard let entry = videoEntry else { return false }
    return ImageInputPrefs.stored(entry.file) ?? entry.takesImage
  }


  /// The person's own word on it, against the app's guess.
  func setTakesImage(_ value: Bool?) {
    guard let entry = videoEntry else { return }
    objectWillChange.send()
    ImageInputPrefs.save(value == entry.takesImage ? nil : value, for: entry.file)
  }


  var takesImageOverridden: Bool { videoEntry.map { ImageInputPrefs.stored($0.file) != nil } ?? false }
}
