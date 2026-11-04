import AVKit
import MediaGenerationKit
import SwiftUI
import Translation
import UniformTypeIdentifiers

@available(macOS 26, *)
struct Stage: View {
  @ObservedObject var s: Studio

  var body: some View {
    switch s.tab {
    case .video: VideoStage(s: s)
    case .edit: EditStage(s: s)
    case .image: pictures
    }
  }

  private var mine: Bool { s.busy && s.running == .image }

  private var pictures: some View {
    VStack(spacing: 0) {
      ZStack {
        P.panel2
        if let live = s.livePreview, mine, s.showProgressPreview {
          VStack(spacing: 12) {
            Image(nsImage: live)
              .resizable().interpolation(.medium).scaledToFit()
              .clipShape(RoundedRectangle(cornerRadius: 6))
              .overlay(
                RoundedRectangle(cornerRadius: 6).stroke(P.line.opacity(0.5), lineWidth: 1))
              .overlay(alignment: .topLeading) {
                HStack(spacing: 6) {
                  Circle().fill(Color(hex: 0xff2d2d)).frame(width: 7, height: 7)
                  Text(s.stepText.uppercased()).font(.mono(9, .bold)).tracking(1)
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
                .padding(12)
              }
          }
          .padding(22)
        } else if s.gridMode, s.batchGroup.count > 1 {
          BatchGrid(s: s).padding(22)
        } else if let f = s.selected {
          Finder(frame: f, busy: mine, stepText: s.stepText, hudShown: s.hudShown)
            .padding(22)
            .onHover { s.hoverHUD($0) }
            .onTapGesture(count: 2) { s.fullscreen = f }
        } else if !mine {
          VStack(spacing: 14) {
            Cap(text: "здесь появится изображение", rule: false)
            Text("напишите Prompt и нажмите «Сгенерировать»")
              .font(.sans(13)).foregroundStyle(P.muted)
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .onHover { s.stageHovered = $0 }
      // a click on the picture takes the keyboard away from the prompt, so the arrows leaf
      .simultaneousGesture(TapGesture().onEnded { NSApp.keyWindow?.makeFirstResponder(nil) })
      .overlay {
        if mine, !(s.showProgressPreview && s.livePreview != nil) {
          WorkingBadge(s: s)
        }
      }
      .overlay(alignment: .topTrailing) {
        HStack(spacing: 8) {
          if s.batchGroup.count > 1 {
            FloatButton(
              symbol: s.gridMode ? "rectangle" : "square.grid.2x2",
              title: s.gridMode ? "ПО ОДНОМУ" : "ВСЕ \(s.batchGroup.count)"
            ) { s.gridMode.toggle() }
          }
          if let frame = s.selected, !mine, !(s.gridMode && s.batchGroup.count > 1) {
            FloatButton(symbol: "wand.and.stars", title: "РЕДАКТИРОВАТЬ") { s.edit(frame) }
              .help("сделать эту картинку исходником для правки")
            AnimateButton(s: s, frame: frame)
          }
          GalleryButton(s: s)
        }
        .padding(16)
      }
    }
    .background(P.panel2)
  }
}
/// While a picture is being made and its in-between steps are hidden: a calm strip instead of
/// noise.
@available(macOS 26, *)
struct WorkingBadge: View {
  @ObservedObject var s: Studio

  private var hint: String {
    if s.stepFraction == 0 {
      let model = Double(s.modelBytes) / 1_073_741_824
      if model > 0, model > s.cacheGB {
        return String(
          format: "подготовка · модель %.0f ГБ больше кэша %.0f ГБ и грузится заново", model, s.cacheGB)
      }
      return "подготовка"
    }
    return s.queued > 0 ? "в очереди ещё \(s.queued)" : "промежуточные шаги скрыты"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack {
        Text("СЧИТАЮ").font(.mono(10, .bold)).tracking(1.4).foregroundStyle(P.accentText)
        Spacer()
        Text(s.stepText.uppercased()).font(.mono(10, .semibold)).foregroundStyle(P.ink)
          .monospacedDigit()
      }
      ProgressView(value: s.stepFraction).tint(P.accent)
      Text(hint)
      .font(.mono(9)).foregroundStyle(P.muted)
    }
    .padding(14)
    .frame(width: 300)
    .background(P.panel)
    .overlay(Rectangle().stroke(P.line, lineWidth: 1))
    .background(Rectangle().fill(P.hair).offset(x: 4, y: 4))
  }
}
@available(macOS 26, *)
struct Finder: View {
  let frame: Frame
  let busy: Bool
  let stepText: String
  let hudShown: Bool

  var body: some View {
    GeometryReader { geo in
      let ratio = CGFloat(frame.width) / CGFloat(frame.height)
      let w = min(geo.size.width, geo.size.height * ratio)
      let h = w / ratio
      ZStack {
        if frame.hasAlpha { Checkerboard().frame(width: w, height: h) }
        Image(nsImage: frame.image)
          .resizable().interpolation(.high).scaledToFill()
          .frame(width: w, height: h).clipped()
        HUD(frame: frame, busy: busy, stepText: stepText)
          .frame(width: w, height: h)
          .opacity(hudShown || busy ? 1 : 0)
          .animation(.easeInOut(duration: 0.45), value: hudShown)
      }
      .frame(width: w, height: h)
      .clipShape(RoundedRectangle(cornerRadius: 6))
      .overlay(RoundedRectangle(cornerRadius: 6).stroke(P.line.opacity(0.6), lineWidth: 1))
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}
/// The grey-and-white squares that say "this part is see-through".
@available(macOS 26, *)
struct Checkerboard: View {
  var body: some View {
    Canvas { context, size in
      let cell: CGFloat = 12
      context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.92)))
      for row in 0..<Int((size.height / cell).rounded(.up)) {
        for column in 0..<Int((size.width / cell).rounded(.up)) where (row + column) % 2 == 0 {
          context.fill(
            Path(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)),
            with: .color(Color(white: 0.78)))
        }
      }
    }
  }
}
@available(macOS 26, *)
struct HUD: View {
  let frame: Frame
  let busy: Bool
  let stepText: String

  var body: some View {
    ZStack {
      VStack {
        HStack(alignment: .top) {
          HStack(spacing: 6) {
            Circle().fill(busy ? Color(hex: 0xff2d2d) : .white.opacity(0.8))
              .frame(width: 8, height: 8)
            Text(busy ? stepText.uppercased() : frame.model.uppercased()).font(.mono(9)).tracking(1)
          }
          Spacer()
          Text("\(frame.width) × \(frame.height)\n\(frame.steps) STEPS")
            .font(.mono(9)).tracking(0.8).multilineTextAlignment(.trailing)
        }
        Spacer()
        HStack {
          Text("SEED \(frame.seed)").font(.mono(9)).tracking(0.8)
          Spacer()
          Text(String(format: "%.1f S", frame.seconds))
            .font(.mono(10)).tracking(0.6).foregroundStyle(P.amber)
        }
      }
      .padding(12)
      .foregroundStyle(.white)
      .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
      Brackets()
    }
  }
}
struct Brackets: View {
  var body: some View {
    GeometryReader { g in
      let s: CGFloat = 16
      let inset: CGFloat = 12
      let top: CGFloat = 32
      Path { p in
        p.move(to: CGPoint(x: inset, y: top + s)); p.addLine(to: CGPoint(x: inset, y: top))
        p.addLine(to: CGPoint(x: inset + s, y: top))
        p.move(to: CGPoint(x: g.size.width - inset - s, y: top))
        p.addLine(to: CGPoint(x: g.size.width - inset, y: top))
        p.addLine(to: CGPoint(x: g.size.width - inset, y: top + s))
        p.move(to: CGPoint(x: inset, y: g.size.height - top - s))
        p.addLine(to: CGPoint(x: inset, y: g.size.height - top))
        p.addLine(to: CGPoint(x: inset + s, y: g.size.height - top))
        p.move(to: CGPoint(x: g.size.width - inset - s, y: g.size.height - top))
        p.addLine(to: CGPoint(x: g.size.width - inset, y: g.size.height - top))
        p.addLine(to: CGPoint(x: g.size.width - inset, y: g.size.height - top - s))
      }
      .stroke(Color.white.opacity(0.8), lineWidth: 2)
    }
  }
}
/// Double-clicking a frame fills the window with it. Click anywhere or press Esc to leave.
@available(macOS 26, *)
struct Fullscreen: View {
  let frame: Frame
  let position: String
  let close: () -> Void

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()
      Image(nsImage: frame.image)
        .resizable().interpolation(.high).scaledToFit()
        .padding(20)
      VStack {
        Spacer()
        HStack(spacing: 14) {
          Text("\(frame.width) × \(frame.height)")
          Text("SEED \(frame.seed)")
          Text(String(format: "%.1f С", frame.seconds)).foregroundStyle(P.amber)
          Spacer()
          Text(
            position.isEmpty
              ? "КЛИК ИЛИ ESC — ЗАКРЫТЬ"
              : "\(position.uppercased()) · ← → ЛИСТАТЬ · ESC — ЗАКРЫТЬ")
        }
        .font(.mono(9)).tracking(1)
        .foregroundStyle(.white.opacity(0.75))
        .padding(.horizontal, 22).padding(.bottom, 16)
      }
    }
    .contentShape(Rectangle())
    .onTapGesture { close() }
    .onExitCommand { close() }
  }
}
