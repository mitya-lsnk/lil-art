import CoreGraphics
import Foundation
import ImageIO
import NNC
import UniformTypeIdentifiers

/// Turns a picture the engine sends back into PNG bytes.
///
/// The kit's own encoder on the Mac assumes three colour channels and an opaque picture.
/// Models with a transparent decoder (Qwen Image 2.1 always uses one) send four: alpha
/// first, in 0…1, then red, green and blue in −1…1 — the order the engine's own
/// `ImageConverter.imageAndMask` reads them in. Read as three channels, every pixel after
/// the first lands in the wrong place and the picture comes out as noise.
enum TensorImage {
  struct Encoded {
    let png: Data
    /// At least one pixel is not fully opaque: worth a checkerboard behind it.
    let hasAlpha: Bool
  }

  static func png<T: TensorNumeric & BinaryFloatingPoint>(_ tensor: Tensor<T>) -> Encoded? {
    let shape = tensor.shape
    guard shape.count >= 3 else { return nil }
    let channels = shape[shape.count - 1]
    let width = shape[shape.count - 2]
    let height = shape[shape.count - 3]
    guard width > 0, height > 0, channels == 3 || channels == 4 else { return nil }

    let pixels = width * height
    var bytes = [UInt8](repeating: 255, count: pixels * 4)
    var transparent = false
    tensor.withUnsafeBytes { raw in
      guard let values = raw.baseAddress?.assumingMemoryBound(to: T.self) else { return }
      let colour = channels == 4 ? 1 : 0
      for index in 0..<pixels {
        let base = index * channels
        bytes[index * 4] = byte((Float(values[base + colour]) + 1) * 127.5)
        bytes[index * 4 + 1] = byte((Float(values[base + colour + 1]) + 1) * 127.5)
        bytes[index * 4 + 2] = byte((Float(values[base + colour + 2]) + 1) * 127.5)
        if channels == 4 {
          let alpha = byte(Float(values[base]) * 255)
          bytes[index * 4 + 3] = alpha
          if alpha < 255 { transparent = true }
        }
      }
    }

    // An opaque picture is written without an alpha channel: smaller, and nothing
    // downstream mistakes it for a cut-out.
    let alphaInfo: CGImageAlphaInfo = transparent ? .last : .noneSkipLast
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let provider = CGDataProvider(data: Data(bytes) as CFData),
      let image = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: space,
        bitmapInfo: CGBitmapInfo(rawValue: alphaInfo.rawValue), provider: provider,
        decode: nil, shouldInterpolate: false, intent: .defaultIntent),
      let output = CFDataCreateMutable(nil, 0),
      let destination = CGImageDestinationCreateWithData(
        output, UTType.png.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return Encoded(png: output as Data, hasAlpha: transparent)
  }

  private static func byte(_ value: Float) -> UInt8 {
    UInt8(min(max((value.isFinite ? value : 0).rounded(), 0), 255))
  }
}
