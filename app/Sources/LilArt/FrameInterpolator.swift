import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Draws the frames in between two given ones with macOS's own frame-rate conversion
/// (VideoToolbox, on the GPU). No model is downloaded and none of ours is involved.
@available(macOS 26, *)
final class FrameInterpolator {
  enum Failure: Error, LocalizedError {
    case unsupported(Int, Int)
    case failed(String)

    var errorDescription: String? {
      switch self {
      case .unsupported(let w, let h): return "macOS не дорисовывает кадры размера \(w)×\(h)"
      case .failed(let why): return "дорисовка кадров не удалась: \(why)"
      }
    }
  }

  private let processor = VTFrameProcessor()
  private let config: VTFrameRateConversionConfiguration
  private let format: OSType
  private let width: Int
  private let height: Int

  init(width: Int, height: Int) throws {
    guard VTFrameRateConversionConfiguration.isSupported,
      let config = VTFrameRateConversionConfiguration(
        frameWidth: width, frameHeight: height, usePrecomputedFlow: false,
        qualityPrioritization: .normal, revision: VTFrameRateConversionConfiguration.defaultRevision),
      let format = (config.frameSupportedPixelFormats as [Any]).first.flatMap({ ($0 as? NSNumber)?.uint32Value }),
      // the drawing below is written for this one layout: four 16-bit floats a pixel
      format == kCVPixelFormatType_64RGBAHalf
    else { throw Failure.unsupported(width, height) }
    self.config = config
    self.format = format
    self.width = width
    self.height = height
    do { try processor.startSession(configuration: config) } catch {
      throw Failure.failed(error.localizedDescription)
    }
  }

  deinit { processor.endSession() }

  /// A drawing surface over a buffer's own memory; the buffer must stay locked while it is used.
  private func context(over buffer: CVPixelBuffer) -> CGContext? {
    guard let base = CVPixelBufferGetBaseAddress(buffer), let space = CGColorSpace(name: CGColorSpace.sRGB)
    else { return nil }
    return CGContext(
      data: base, width: width, height: height, bitsPerComponent: 16,
      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
        | CGBitmapInfo.byteOrder16Little.rawValue)
  }

  private func emptyBuffer(_ attributes: [String: Any]) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, width, height, format, attributes as CFDictionary, &buffer)
    guard let buffer else { throw Failure.failed("нет памяти под кадр") }
    return buffer
  }

  /// A frame in the form the converter takes.
  func source(_ image: CGImage) throws -> CVPixelBuffer {
    let buffer = try emptyBuffer(config.sourcePixelBufferAttributes)
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let context = context(over: buffer) else { throw Failure.failed("кадр не прочитался") }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return buffer
  }

  /// The frame `phase` of the way from `a` to `b` (0 < phase < 1).
  func between(_ a: CVPixelBuffer, _ b: CVPixelBuffer, phase: Double) async throws -> CGImage {
    let made = try emptyBuffer(config.destinationPixelBufferAttributes)
    guard
      let first = VTFrameProcessorFrame(buffer: a, presentationTimeStamp: CMTime(value: 0, timescale: 1000)),
      let second = VTFrameProcessorFrame(buffer: b, presentationTimeStamp: CMTime(value: 1000, timescale: 1000)),
      let target = VTFrameProcessorFrame(
        buffer: made, presentationTimeStamp: CMTime(value: CMTimeValue(phase * 1000), timescale: 1000)),
      let parameters = VTFrameRateConversionParameters(
        sourceFrame: first, nextFrame: second, opticalFlow: nil, interpolationPhase: [Float(phase)],
        submissionMode: .random, destinationFrames: [target])
    else { throw Failure.failed("кадры не приняты") }
    let error: Error? = await withCheckedContinuation { done in
      processor.process(parameters: parameters) { _, error in done.resume(returning: error) }
    }
    if let error { throw Failure.failed(error.localizedDescription) }
    CVPixelBufferLockBaseAddress(made, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(made, .readOnly) }
    guard let image = context(over: made)?.makeImage() else { throw Failure.failed("кадр не получился") }
    return image
  }
}
