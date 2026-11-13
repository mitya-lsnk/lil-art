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
    case refused(String)

    var errorDescription: String? {
      switch self {
      case .refused(let why): return why
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

/// Makes a frame larger with macOS's own video scaler (VideoToolbox, on the GPU): sharper than
/// plain stretching, and nearly free next to asking the model for a larger frame.
@available(macOS 26, *)
final class FrameUpscaler {
  private let processor = VTFrameProcessor()
  private let config: VTLowLatencySuperResolutionScalerConfiguration
  private var transfer: VTPixelTransferSession?
  private let width: Int
  private let height: Int
  let outWidth: Int
  let outHeight: Int

  init(width: Int, height: Int, factor: Double) throws {
    guard VTLowLatencySuperResolutionScalerConfiguration.isSupported,
      VTLowLatencySuperResolutionScalerConfiguration.supportedScaleFactors(frameWidth: width, frameHeight: height)
        .contains(where: { abs(Double($0) - factor) < 0.01 })
    else {
      throw FrameInterpolator.Failure.refused(
        String(format: "macOS не увеличивает кадр %d×%d в %.1f раза", width, height, factor))
    }
    config = VTLowLatencySuperResolutionScalerConfiguration(
      frameWidth: width, frameHeight: height, scaleFactor: Float(factor))
    self.width = width
    self.height = height
    let out = config.destinationPixelBufferAttributes
    outWidth = (out[kCVPixelBufferWidthKey as String] as? NSNumber)?.intValue ?? Int(Double(width) * factor)
    outHeight = (out[kCVPixelBufferHeightKey as String] as? NSNumber)?.intValue ?? Int(Double(height) * factor)
    VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
    do { try processor.startSession(configuration: config) } catch {
      throw FrameInterpolator.Failure.failed(error.localizedDescription)
    }
  }

  deinit { processor.endSession() }

  private static let rgb = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

  private func buffer(_ w: Int, _ h: Int, _ format: OSType, _ attributes: [String: Any] = [:]) throws -> CVPixelBuffer {
    var made: CVPixelBuffer?
    var all = attributes
    all[kCVPixelBufferIOSurfacePropertiesKey as String] = [String: Any]()
    CVPixelBufferCreate(nil, w, h, format, all as CFDictionary, &made)
    guard let made else { throw FrameInterpolator.Failure.failed("нет памяти под кадр") }
    return made
  }

  private func context(over buffer: CVPixelBuffer) -> CGContext? {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    return CGContext(
      data: CVPixelBufferGetBaseAddress(buffer), width: CVPixelBufferGetWidth(buffer),
      height: CVPixelBufferGetHeight(buffer), bitsPerComponent: 8,
      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space, bitmapInfo: Self.rgb)
  }

  func upscale(_ image: CGImage) async throws -> CGImage {
    guard let transfer else { throw FrameInterpolator.Failure.failed("нет преобразователя кадров") }
    let yuv = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    // picture → the scaler's own form (video YUV) → larger → back to a picture
    let plain = try buffer(width, height, kCVPixelFormatType_32BGRA)
    CVPixelBufferLockBaseAddress(plain, [])
    context(over: plain)?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    CVPixelBufferUnlockBaseAddress(plain, [])
    let source = try buffer(width, height, yuv, config.sourcePixelBufferAttributes)
    let target = try buffer(outWidth, outHeight, yuv, config.destinationPixelBufferAttributes)
    guard VTPixelTransferSessionTransferImage(transfer, from: plain, to: source) == noErr,
      let from = VTFrameProcessorFrame(buffer: source, presentationTimeStamp: .zero),
      let to = VTFrameProcessorFrame(buffer: target, presentationTimeStamp: .zero)
    else { throw FrameInterpolator.Failure.failed("кадр не принят увеличителем") }
    let parameters = VTLowLatencySuperResolutionScalerParameters(sourceFrame: from, destinationFrame: to)
    let error: Error? = await withCheckedContinuation { done in
      processor.process(parameters: parameters) { _, error in done.resume(returning: error) }
    }
    if let error { throw FrameInterpolator.Failure.failed(error.localizedDescription) }
    let large = try buffer(outWidth, outHeight, kCVPixelFormatType_32BGRA)
    guard VTPixelTransferSessionTransferImage(transfer, from: target, to: large) == noErr else {
      throw FrameInterpolator.Failure.failed("увеличенный кадр не прочитался")
    }
    CVPixelBufferLockBaseAddress(large, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(large, .readOnly) }
    guard let made = context(over: large)?.makeImage() else {
      throw FrameInterpolator.Failure.failed("увеличенный кадр не получился")
    }
    return made
  }
}
