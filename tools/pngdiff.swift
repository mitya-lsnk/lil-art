import CoreGraphics
import Foundation
import ImageIO

// Mean and largest per-channel difference between two pictures, 0…255.
// Used by golden.sh when two pictures that should be identical are not byte for byte.
func pixels(_ path: String) -> (w: Int, h: Int, data: [UInt8])? {
  guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
  else { return nil }
  let w = image.width, h = image.height
  var data = [UInt8](repeating: 0, count: w * h * 4)
  guard let context = CGContext(
    data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
  else { return nil }
  context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
  return (w, h, data)
}

let args = CommandLine.arguments
guard args.count == 3, let a = pixels(args[1]), let b = pixels(args[2]) else {
  print("не удалось прочитать картинки")
  exit(2)
}
guard a.w == b.w, a.h == b.h else {
  print("размеры разные: \(a.w)×\(a.h) и \(b.w)×\(b.h)")
  exit(1)
}
var total = 0, worst = 0
for i in 0..<a.data.count where i % 4 != 3 {
  let d = abs(Int(a.data[i]) - Int(b.data[i]))
  total += d
  worst = max(worst, d)
}
let mean = Double(total) / Double(a.w * a.h * 3)
print(String(format: "среднее отличие %.4f из 255, наибольшее %d", mean, worst))
// The engine does not repeat itself to the last bit: two runs of the same seed differ by
// well under one level on average (measured 2026-11-04). Anything above this is a real change.
let noise = 0.5
print(mean < noise ? "в пределах шума движка" : "ЗАМЕТНОЕ ОТЛИЧИЕ")
exit(mean < noise ? 0 : 1)
