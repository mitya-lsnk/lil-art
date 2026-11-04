import ImageIO
import SwiftUI

@available(macOS 26, *)
extension Studio {
  var regionsAvailable: Bool { modelEntry.map { RegionLayout.supports(family: $0.family) } ?? false }

  /// The boxes of the tab in front: the picture tab and the edit tab keep their own.
  var tabRegions: [Region] {
    get { tab == .edit ? editRegions : regions }
    set { if tab == .edit { editRegions = newValue } else { regions = newValue } }
  }

  /// Boxes that go with a run of this tab, nil when the model does not read them.
  func regionsInUse(edit: Bool) -> [Region] {
    guard regionsAvailable else { return [] }
    return (edit ? editRegions : regions).filter { !$0.modelText.isEmpty }
  }

  func removeRegion(_ id: UUID) {
    var list = tabRegions
    list.removeAll { $0.id == id }
    // numbers follow the order on screen, so the list reads 1, 2, 3 after a removal too
    for i in list.indices { list[i].number = i + 1 }
    tabRegions = list
  }

  func setRegionText(_ id: UUID, _ text: String) {
    var list = tabRegions
    guard let i = list.firstIndex(where: { $0.id == id }) else { return }
    list[i].text = text
    tabRegions = list
  }
}

/// The boxes drawn over a picture or an empty frame. A drag on empty space draws a new box;
/// a drag inside one moves it, from its lower right corner resizes it. In an edit moving a box
/// leaves its dashed outline where the element was: that is "move it from here to there".
@available(macOS 26, *)
struct RegionCanvas: View {
  @Binding var regions: [Region]
  let edit: Bool
  var interactive = true

  private enum Mode { case draw(UUID), move(UUID, CGRect), resize(UUID, CGRect) }
  private var _mode = SwiftUI.State<Mode?>(initialValue: nil)
  private var mode: Mode? {
    get { _mode.wrappedValue }
    nonmutating set { _mode.wrappedValue = newValue }
  }

  init(regions: Binding<[Region]>, edit: Bool, interactive: Bool = true) {
    _regions = regions
    self.edit = edit
    self.interactive = interactive
  }

  var body: some View {
    GeometryReader { geo in
      let size = geo.size
      ZStack(alignment: .topLeading) {
        Color.clear
        ForEach(regions) { region in
          let target = scaled(region.box, size)
          if edit, region.moved {
            let from = scaled(region.source, size)
            Rectangle()
              .stroke(P.accent.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
              .frame(width: from.width, height: from.height)
              .offset(x: from.minX, y: from.minY)
            Path { p in
              p.move(to: CGPoint(x: from.midX, y: from.midY))
              p.addLine(to: CGPoint(x: target.midX, y: target.midY))
            }
            .stroke(P.accent.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
          }
          Rectangle()
            .fill(P.accent.opacity(0.12))
            .overlay(Rectangle().stroke(P.accent, lineWidth: 1.5))
            .frame(width: target.width, height: target.height)
            .offset(x: target.minX, y: target.minY)
          Text("\(region.number)")
            .font(.mono(10, .bold))
            .foregroundStyle(P.accentInk)
            .padding(.horizontal, 4).frame(height: 15)
            .background(P.accent)
            .offset(x: target.minX, y: target.minY)
          if interactive {
            Rectangle().fill(P.accent).frame(width: 7, height: 7)
              .offset(x: target.maxX - 3.5, y: target.maxY - 3.5)
          }
        }
      }
      .frame(width: size.width, height: size.height, alignment: .topLeading)
      .contentShape(Rectangle())
      .gesture(drag(size), including: interactive ? .all : .none)
    }
    .allowsHitTesting(interactive)
  }

  private func scaled(_ r: CGRect, _ size: CGSize) -> CGRect {
    CGRect(x: r.minX * size.width, y: r.minY * size.height,
           width: r.width * size.width, height: r.height * size.height)
  }

  private func drag(_ size: CGSize) -> some Gesture {
    DragGesture(minimumDistance: 2)
      .onChanged { value in
        guard size.width > 0, size.height > 0 else { return }
        let start = CGPoint(x: value.startLocation.x / size.width, y: value.startLocation.y / size.height)
        let now = CGPoint(
          x: min(1, max(0, value.location.x / size.width)),
          y: min(1, max(0, value.location.y / size.height)))
        if mode == nil { mode = begin(at: value.startLocation, normalized: start, size: size) }
        switch mode {
        case .draw(let id):
          let r = CGRect(
            x: min(start.x, now.x), y: min(start.y, now.y),
            width: abs(now.x - start.x), height: abs(now.y - start.y))
          update(id) { $0.box = r; $0.source = r }
        case .move(let id, let origin):
          var r = origin
          r.origin.x = min(1 - r.width, max(0, origin.minX + now.x - start.x))
          r.origin.y = min(1 - r.height, max(0, origin.minY + now.y - start.y))
          // in an edit the element moves from where it is; on a blank frame the box simply moves
          update(id) { region in
            if !edit { region.source = r }
            region.box = r
          }
        case .resize(let id, let origin):
          let r = CGRect(
            x: origin.minX, y: origin.minY,
            width: max(0.03, now.x - origin.minX), height: max(0.03, now.y - origin.minY))
          update(id) { region in
            // a box not yet moved marks where the element is, so both places change together
            if !region.moved { region.source = r }
            region.box = r
          }
        case nil: break
        }
      }
      .onEnded { _ in
        if case .draw(let id) = mode,
          let r = regions.first(where: { $0.id == id })?.box, r.width < 0.03 || r.height < 0.03
        {
          regions.removeAll { $0.id == id }
        }
        mode = nil
      }
  }

  private func begin(at point: CGPoint, normalized: CGPoint, size: CGSize) -> Mode {
    for region in regions.reversed() {
      let r = scaled(region.box, size)
      if abs(point.x - r.maxX) < 9, abs(point.y - r.maxY) < 9 { return .resize(region.id, region.box) }
      if r.contains(point) { return .move(region.id, region.box) }
    }
    let r = CGRect(origin: normalized, size: .zero)
    let fresh = Region(number: regions.count + 1, box: r, source: r)
    regions.append(fresh)
    return .draw(fresh.id)
  }

  private func update(_ id: UUID, _ change: (inout Region) -> Void) {
    guard let i = regions.firstIndex(where: { $0.id == id }) else { return }
    change(&regions[i])
  }
}

/// The zones block in the sidebar: the list of boxes with their descriptions and, on the
/// picture tab, a frame of the chosen size to draw them on. On the edit tab they are drawn
/// over the picture itself.
@available(macOS 26, *)
struct RegionsBlock: View {
  @ObservedObject var s: Studio

  var body: some View {
    let edit = s.tab == .edit
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Cap(text: "зоны")
        InfoDot(
          text: edit
            ? "обведите рамкой предмет на картинке и опишите его. потяните рамку — предмет переедет туда. рамка — подсказка, а не маска"
            : "нарисуйте рамку там, где должен быть предмет, и опишите его. в Prompt можно сослаться на зону как <region_1>. рамка — подсказка, а не маска")
        Spacer()
        if !s.tabRegions.isEmpty {
          Button { s.tabRegions = [] } label: {
            Text("очистить").font(.mono(9, .bold)).tracking(0.8).foregroundStyle(P.muted)
          }
          .buttonStyle(.plain)
        }
      }
      if !edit {
        // an exact size: a greedy frame inside the sidebar's scroll view kept the layout
        // recomputing itself, which slowed the whole window and pushed the sidebar wide
        let (w, h) = s.effectiveSize
        let ratio = CGFloat(max(1, w)) / CGFloat(max(1, h))
        let side: CGFloat = 356
        let height = min(260, side / ratio)
        let width = min(side, height * ratio)
        ZStack {
          P.panel
          RegionCanvas(regions: $s.regions, edit: false)
        }
        .frame(width: width, height: height)
        .overlay(Rectangle().stroke(P.line, lineWidth: 1))
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      ForEach(s.tabRegions) { region in
        HStack(spacing: 6) {
          Text("\(region.number)")
            .font(.mono(10, .bold)).foregroundStyle(P.accentInk)
            .frame(width: 20, height: 26).background(P.accent)
          TextField(
            edit ? "что это за предмет" : "что здесь",
            text: Binding(get: { region.text }, set: { s.setRegionText(region.id, $0) }))
            .textFieldStyle(.plain).font(.mono(11))
            .padding(.horizontal, 8).frame(height: 26)
            .background(P.panel).overlay(Rectangle().stroke(P.line, lineWidth: 1))
          Button { s.removeRegion(region.id) } label: {
            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
              .foregroundStyle(P.muted).frame(width: 22, height: 26)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
      }
      if s.tabRegions.isEmpty {
        Text(edit ? "рамок нет — правка без разметки" : "рамок нет — модель расставит всё сама")
          .font(.mono(9)).foregroundStyle(P.muted)
      } else if s.tabRegions.contains(where: { !$0.text.isEmpty && $0.englishSource != $0.text }) {
        Text("описания зон переводятся вместе с Prompt кнопкой «перевести»")
          .font(.mono(9)).foregroundStyle(P.muted)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}
