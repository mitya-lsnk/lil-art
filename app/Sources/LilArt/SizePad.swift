import SwiftUI

/// A field of dots where one dot is 64 pixels, the step the engine insists on. Drag from
/// the corner and the rectangle grows in real steps, so the size is chosen by looking
/// rather than by typing. The whole field is 4096 across, which is the ceiling.
///
/// A drag that starts on the right edge moves only the width, on the bottom edge only the
/// height; a locked side never moves at all.
@available(macOS 26, *)
struct SizePad: View {
  @Binding var width: Int
  @Binding var height: Int
  var lockWidth = false
  var lockHeight = false

  private enum Grip { case both, width, height }
  private var _grip = SwiftUI.State<Grip?>(initialValue: nil)
  private var grip: Grip? {
    get { _grip.wrappedValue }
    nonmutating set { _grip.wrappedValue = newValue }
  }

  init(width: Binding<Int>, height: Binding<Int>, lockWidth: Bool = false, lockHeight: Bool = false) {
    _width = width
    _height = height
    self.lockWidth = lockWidth
    self.lockHeight = lockHeight
  }

  private let step = 64
  private let maxSide = 4096
  private var cells: Int { maxSide / step }  // 64 dots per side

  var body: some View {
    GeometryReader { geo in
      let side = min(geo.size.width, geo.size.height)
      let unit = side / CGFloat(cells)
      let w = CGFloat(width / step) * unit
      let h = CGFloat(height / step) * unit

      ZStack(alignment: .topLeading) {
        DotField(cells: cells, unit: unit)
          .frame(width: side, height: side)

        Rectangle()
          .fill(P.accent.opacity(0.16))
          .frame(width: max(unit, w), height: max(unit, h))
          .overlay(
            Rectangle().stroke(P.accent, lineWidth: 1.5)
              .frame(width: max(unit, w), height: max(unit, h)))

        // the handle sits on the far corner of the rectangle; the edges are handles too
        Rectangle()
          .fill(P.accent)
          .frame(width: 9, height: 9)
          .offset(x: max(unit, w) - 4.5, y: max(unit, h) - 4.5)
        Rectangle()
          .fill(lockWidth ? P.muted.opacity(0.4) : P.accent)
          .frame(width: 3, height: 18)
          .offset(x: max(unit, w) - 1.5, y: max(unit, h) / 2 - 9)
        Rectangle()
          .fill(lockHeight ? P.muted.opacity(0.4) : P.accent)
          .frame(width: 18, height: 3)
          .offset(x: max(unit, w) / 2 - 9, y: max(unit, h) - 1.5)
      }
      .frame(width: side, height: side, alignment: .topLeading)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in
            if grip == nil {
              // which handle the drag started on: near the right edge only, the width;
              // near the bottom edge only, the height; anywhere else, both
              let start = value.startLocation
              let nearRight = abs(start.x - max(unit, w)) < 10
              let nearBottom = abs(start.y - max(unit, h)) < 10
              grip = nearRight && !nearBottom ? .width : nearBottom && !nearRight ? .height : .both
            }
            let cx = Int((value.location.x / unit).rounded(.up))
            let cy = Int((value.location.y / unit).rounded(.up))
            // the engine snaps anything under 256 up to 256, so the pad never offers less
            let least = max(step, 256)
            if !lockWidth, grip != .height { width = min(maxSide, max(least, cx * step)) }
            if !lockHeight, grip != .width { height = min(maxSide, max(least, cy * step)) }
          }
          .onEnded { _ in grip = nil })
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .aspectRatio(1, contentMode: .fit)
  }
}

/// Drawn once into a Canvas: 4096 dots would be far too many separate views.
@available(macOS 26, *)
private struct DotField: View {
  let cells: Int
  let unit: CGFloat

  var body: some View {
    // read here, in the body, so a change of skin redraws the dots
    let ink = P.ink
    return Canvas { context, size in
      let r: CGFloat = 0.9
      for x in 0...cells {
        for y in 0...cells {
          // every fourth dot, meaning every 256 pixels, is a little stronger
          let major = x % 4 == 0 && y % 4 == 0
          let point = CGPoint(x: CGFloat(x) * unit, y: CGFloat(y) * unit)
          let rect = CGRect(
            x: point.x - r, y: point.y - r, width: r * 2, height: r * 2)
          context.fill(
            Path(ellipseIn: rect),
            with: .color(ink.opacity(major ? 0.34 : 0.13)))
        }
      }
      _ = size
    }
    .background(P.panel)
    .overlay(Rectangle().stroke(P.line, lineWidth: 1))
  }
}
