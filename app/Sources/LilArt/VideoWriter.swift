import AVFoundation
import AppKit
import CoreVideo
import Foundation

/// Turns the frames the engine hands back into one file you can play, send or drop into
/// a timeline.
///
/// The engine never makes a video: it makes pictures, one per frame, and stops. Every
/// program that generates video assembles them afterwards, and on a Mac that is
/// AVFoundation — no ffmpeg, nothing to download, the same encoder Final Cut uses.
enum VideoWriter {
  enum Format: String, CaseIterable, Codable, Hashable {
    /// Plays everywhere, small files. The sane default.
    case h264
    /// Same size at better quality, but older programs choke on it.
    case hevc
    /// Huge and lossless, for editing rather than sending.
    case proRes

    var label: String {
      switch self {
      case .h264: return "H.264 · mp4"
      case .hevc: return "HEVC · mp4"
      case .proRes: return "ProRes 4444 · mov"
      }
    }

    var fileExtension: String { self == .proRes ? "mov" : "mp4" }

    var fileType: AVFileType { self == .proRes ? .mov : .mp4 }

    var codec: AVVideoCodecType {
      switch self {
      case .h264: return .h264
      case .hevc: return .hevc
      case .proRes: return .proRes4444
      }
    }

    /// The encoder's default bitrate is tuned for camera footage and leaves generated detail
    /// smeared, so ask for about 0.2 bits per pixel per frame (never under 2 Mbps).
    /// ProRes is fixed-quality and must not be given a bitrate at all.
    func compression(width: Int, height: Int, fps: Double) -> [String: Any]? {
      guard self != .proRes else { return nil }
      let perSecond = Double(width) * Double(height) * max(1, fps)
      var properties: [String: Any] = [
        AVVideoAverageBitRateKey: max(2_000_000, Int(perSecond * 0.2)),
        AVVideoExpectedSourceFrameRateKey: Int(max(1, fps).rounded()),
      ]
      if self == .h264 { properties[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
      return properties
    }
  }

  enum Failure: LocalizedError {
    case noFrames
    case unreadableFrame(Int)
    case refused(String)

    var errorDescription: String? {
      switch self {
      case .noFrames: return "движок не вернул ни одного кадра"
      case .unreadableFrame(let i): return "кадр \(i + 1) не читается"
      case .refused(let why): return "не удалось собрать файл: \(why)"
      }
    }
  }

  /// What a clip came out as, and why it was left as it was when frames could not be drawn in.
  struct Written {
    var frames: Int
    var fps: Int
    var note: String?
  }

  /// `pngs` are the frames in order, exactly as the engine produced them; `finish` says whether
  /// frames are drawn in between (smoother or longer). If macOS cannot draw them (a size it does
  /// not take), the clip is written as it is and the reason comes back in `note`: twenty minutes
  /// of generation are never thrown away over the finishing touch.
  @available(macOS 26, *)
  static func write(
    pngs: [Data], fps: Int, finish: VideoFinish, upscale: VideoUpscale = .none, to url: URL, format: Format
  ) async throws -> Written {
    guard let first = pngs.first, let firstImage = decode(first) else { throw Failure.noFrames }
    var notes: [String] = []
    var plan = finish.plan(frames: pngs.count, fps: fps)
    let same = finish.plan(frames: pngs.count, fps: fps) == VideoFinish.asIs.plan(frames: pngs.count, fps: fps)
    var drawer: FrameInterpolator?
    if !same {
      do { drawer = try FrameInterpolator(width: firstImage.width, height: firstImage.height) } catch {
        notes.append(error.localizedDescription)
        plan = VideoFinish.asIs.plan(frames: pngs.count, fps: fps)
      }
    }
    var scaler: FrameUpscaler?
    if upscale != .none {
      do {
        scaler = try FrameUpscaler(width: firstImage.width, height: firstImage.height, factor: upscale.rawValue)
      } catch { notes.append(error.localizedDescription) }
    }
    // the two source frames around the one being drawn, in the converter's form
    var held: [Int: CVPixelBuffer] = [:]
    func source(_ index: Int) throws -> CVPixelBuffer {
      if let buffer = held[index] { return buffer }
      guard let image = decode(pngs[index]), let drawer else { throw Failure.unreadableFrame(index) }
      let buffer = try drawer.source(image)
      held = held.filter { $0.key >= index - 1 }
      held[index] = buffer
      return buffer
    }
    let steps = plan.frames
    func frame(_ number: Int) async throws -> CGImage? {
      let step = steps[number]
      var image: CGImage?
      if step.phase == 0 || drawer == nil {
        image = number == 0 ? firstImage : decode(pngs[step.index])
      } else if let drawer {
        image = try await drawer.between(try source(step.index), try source(step.index + 1), phase: step.phase)
      }
      // frames are drawn in between at the small size, then each is made larger
      if let scaler, let small = image { image = try await scaler.upscale(small) }
      return image
    }
    do {
      guard let opening = try await frame(0) else { throw Failure.unreadableFrame(0) }
      try await write(count: steps.count, first: opening, fps: Double(plan.fps), to: url, format: format) {
        try await frame($0)
      }
    } catch let error as FrameInterpolator.Failure {
      // the finishing touch failed halfway: the model's own frames are still worth a file
      try await write(pngs: pngs, fps: Double(fps), to: url, format: format)
      return Written(frames: pngs.count, fps: fps, note: error.localizedDescription)
    }
    return Written(frames: steps.count, fps: plan.fps, note: notes.isEmpty ? nil : notes.joined(separator: ". "))
  }

  /// `pngs` are the frames in order, exactly as the engine produced them.
  static func write(pngs: [Data], fps: Double, to url: URL, format: Format) async throws {
    guard let first = pngs.first, let firstImage = decode(first) else { throw Failure.noFrames }
    try await write(count: pngs.count, first: firstImage, fps: fps, to: url, format: format) {
      decode(pngs[$0])
    }
  }

  /// The file itself: `count` frames, each asked of `frame` when its turn comes.
  private static func write(
    count: Int, first firstImage: CGImage, fps: Double, to url: URL, format: Format,
    frame: (Int) async throws -> CGImage?
  ) async throws {
    let width = firstImage.width
    let height = firstImage.height

    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: format.fileType)
    var settings: [String: Any] = [
      AVVideoCodecKey: format.codec,
      AVVideoWidthKey: width,
      AVVideoHeightKey: height,
      // Untagged video is guessed at by players, and the guess differs between them; the
      // same tag goes on every pixel buffer below so the encoder converts with this matrix.
      AVVideoColorPropertiesKey: [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
      ],
    ]
    if let compression = format.compression(width: width, height: height, fps: fps) {
      settings[AVVideoCompressionPropertiesKey] = compression
    }
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
      ])
    guard writer.canAdd(input) else { throw Failure.refused("формат не принял кадры") }
    writer.add(input)
    guard writer.startWriting() else {
      try? FileManager.default.removeItem(at: url)
      throw Failure.refused(writer.error?.localizedDescription ?? "запись не началась")
    }
    writer.startSession(atSourceTime: .zero)

    do {
      // A whole-number timescale keeps 16 and 24 frames a second exact, with no drift over
      // a long clip.
      let timescale = CMTimeScale((fps * 1000).rounded())
      for index in 0..<count {
        try Task.checkCancellation()
        guard let image = index == 0 ? firstImage : try await frame(index) else {
          throw Failure.unreadableFrame(index)
        }
        while !input.isReadyForMoreMediaData {
          if writer.status != .writing {
            throw Failure.refused(writer.error?.localizedDescription ?? "запись оборвалась")
          }
          try await Task.sleep(nanoseconds: 5_000_000)
        }
        guard
          let buffer = pixelBuffer(from: image, width: width, height: height, pool: adaptor.pixelBufferPool)
        else { throw Failure.unreadableFrame(index) }
        let time = CMTime(value: CMTimeValue(index * 1000), timescale: timescale)
        if !adaptor.append(buffer, withPresentationTime: time) {
          throw Failure.refused(writer.error?.localizedDescription ?? "кадр не записался")
        }
      }
      input.markAsFinished()

      await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        writer.finishWriting { done.resume() }
      }
      if writer.status != .completed {
        throw Failure.refused(writer.error?.localizedDescription ?? "файл не закрылся")
      }
    } catch {
      // A half-written file looks like a finished one to the gallery and to the player, so
      // nothing is left at the destination when anything went wrong.
      if writer.status == .writing { writer.cancelWriting() }
      try? FileManager.default.removeItem(at: url)
      throw error
    }
  }

  static func decode(_ data: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
  }

  private static func pixelBuffer(
    from image: CGImage, width: Int, height: Int, pool: CVPixelBufferPool?
  ) -> CVPixelBuffer? {
    var buffer: CVPixelBuffer?
    if let pool {
      CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
    }
    if buffer == nil {
      CVPixelBufferCreate(
        kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
        [
          kCVPixelBufferCGImageCompatibilityKey: true,
          kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ] as CFDictionary, &buffer)
    }
    guard let buffer else { return nil }
    CVBufferSetAttachment(
      buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2,
      .shouldPropagate)
    CVBufferSetAttachment(
      buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2,
      .shouldPropagate)
    CVBufferSetAttachment(
      buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(buffer),
      let context = CGContext(
        data: base, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return buffer
  }
}
