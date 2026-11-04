import AVKit
import MediaGenerationKit
import SwiftUI
import Translation
import UniformTypeIdentifiers

/// Everything an editing model needs: the picture to change, up to three to borrow from,
/// and a nudge on how to ask. Appears by itself when the chosen model can edit.
@available(macOS 26, *)
struct EditBox: View {
  @ObservedObject var s: Studio

  private var _over = SwiftUI.State(initialValue: false)
  private var over: Bool {
    get { _over.wrappedValue }
    nonmutating set { _over.wrappedValue = newValue }
  }

  init(s: Studio) { self.s = s }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Cap(text: "что правим")
        Spacer()
        if s.editSource != nil {
          Button { s.clearEditSource() } label: {
            Text("убрать").font(.mono(9, .bold)).tracking(0.8).foregroundStyle(P.muted)
          }
          .buttonStyle(.plain)
        }
      }

      if let source = s.editSource {
        HStack(spacing: 10) {
          Image(nsImage: source.thumb)
            .resizable().scaledToFill()
            .frame(width: 92, height: 92).clipped()
            .overlay(Rectangle().stroke(P.line, lineWidth: 1))
            .overlay(alignment: .topLeading) { PictureNumber(number: 1) }
          VStack(alignment: .leading, spacing: 4) {
            Text(source.url.lastPathComponent)
              .font(.mono(10)).foregroundStyle(P.ink).lineLimit(1).truncationMode(.middle)
            Text("для модели это картинка 1: она изменит её так, как написано в Prompt")
              .font(.mono(9)).tracking(0.2).foregroundStyle(P.muted)
              .fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: 0)
        }
      } else {
        Button { s.pickEditSource() } label: {
          VStack(spacing: 5) {
            Image(systemName: "photo.badge.plus").font(.system(size: 16)).foregroundStyle(P.muted)
            Text("перетащите картинку или нажмите")
              .font(.mono(9)).tracking(0.3).foregroundStyle(P.muted)
          }
          .frame(maxWidth: .infinity).frame(height: 76)
          .background(over ? P.accent.opacity(0.12) : P.panel2)
          .overlay(
            Rectangle().stroke(
              over ? P.accent : P.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dropDestination(for: DroppedPicture.self) { items, _ in
          guard let url = items.lazy.compactMap({ $0.fileURL }).first else { return false }
          s.setEditSource(url)
          return true
        } isTargeted: { over = $0 }
      }

      // pictures to borrow from: a face, a costume, a style
      VStack(alignment: .leading, spacing: 6) {
        Text("ещё картинки · лицо, костюм, стиль · до \(Studio.maxEditRefs) · номер в углу — как их зовёт модель")
          .font(.mono(9)).tracking(0.3).foregroundStyle(P.muted)
          .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 6) {
          ForEach(Array(s.editRefs.enumerated()), id: \.element.id) { index, ref in
            Image(nsImage: ref.thumb)
              .resizable().scaledToFill()
              .frame(width: 52, height: 52).clipped()
              .overlay(Rectangle().stroke(P.line, lineWidth: 1))
              .overlay(alignment: .topLeading) { PictureNumber(number: firstRefNumber + index) }
              .overlay(alignment: .topTrailing) {
                Button { s.removeEditRef(ref) } label: {
                  Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white).frame(width: 15, height: 15)
                    .background(Color.black.opacity(0.6))
                }
                .buttonStyle(.plain)
              }
              .help(ref.url.lastPathComponent)
          }
          if s.editRefs.count < Studio.maxEditRefs {
            Button { s.pickEditRef() } label: {
              Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                .foregroundStyle(P.muted)
                .frame(width: 52, height: 52)
                .overlay(
                  Rectangle().stroke(P.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .dropDestination(for: DroppedPicture.self) { items, _ in
              let images = items.compactMap(\.fileURL)
              images.forEach { s.addEditRef($0) }
              return !images.isEmpty
            }
          }
          Spacer(minLength: 0)
        }
      }

      RecentStills(
        s: s,
        caption: "недавние · нажмите — править эту, правая кнопка — добавить как ещё одну",
        pick: { s.setEditSource($0) },
        options: [
          ("Править эту", { s.setEditSource($0) }),
          ("Добавить как ещё одну", { s.addEditRef($0) }),
        ],
        chosen: { url in s.editSource?.url == url || s.editRefs.contains { $0.url == url } })

      Text(
        "в Prompt напишите, что изменить: «переодень в доспехи», «фон — лесная поляна». "
          + "на картинки ссылайтесь по номерам: «перерисуй картинку 1 в стиле картинки 2», "
          + "«надень куртку с картинки 2 на человека с картинки 1». без картинки модель рисует с нуля."
      )
      .font(.mono(9)).tracking(0.3).foregroundStyle(P.ink.opacity(0.35))
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  /// The engine numbers the pictures in the order it gets them: the one being edited is 1, the
  /// extra ones follow. With nothing to edit the extra ones start at 1.
  private var firstRefNumber: Int { s.editSource == nil ? 1 : 2 }

}
/// The number a picture goes by in the prompt ("картинка 2"), in its corner.
@available(macOS 26, *)
struct PictureNumber: View {
  let number: Int

  var body: some View {
    Text("\(number)")
      .font(.mono(9, .bold)).foregroundStyle(P.accentInk)
      .frame(width: 16, height: 16)
      .background(P.accent)
  }
}
/// The middle of the edit tab: the picture being edited, big, with the mask painted over it;
/// or the latest result, with a way back and a way to keep editing it.
@available(macOS 26, *)
struct EditStage: View {
  @ObservedObject var s: Studio

  private var _over = SwiftUI.State(initialValue: false)
  private var over: Bool {
    get { _over.wrappedValue }
    nonmutating set { _over.wrappedValue = newValue }
  }

  init(s: Studio) { self.s = s }

  private var mine: Bool { s.busy && s.running == .edit }

  var body: some View {
    ZStack {
      P.panel2
      if let live = s.livePreview, mine, s.showProgressPreview {
        Image(nsImage: live)
          .resizable().interpolation(.medium).scaledToFit()
          .clipShape(RoundedRectangle(cornerRadius: 6))
          .padding(22)
      } else if s.editShowResult, let frame = s.editResult {
        Finder(frame: frame, busy: mine, stepText: s.stepText, hudShown: s.hudShown)
          .padding(22)
          .onTapGesture(count: 2) { s.fullscreen = frame }
      } else if let source = s.editSource {
        MaskCanvas(
          url: source.url, mask: $s.editMask, brush: s.maskBrush, erasing: s.maskErasing)
          .overlay {
            // the zones lie over the picture as it is fitted into the stage
            if s.regionsAvailable, s.regionDrawing || !s.editRegions.isEmpty,
              let pixels = RegionLayout.pixelSize(source.url)
            {
              GeometryReader { geo in
                let scale = min(geo.size.width / pixels.width, geo.size.height / pixels.height)
                let fitted = CGSize(width: pixels.width * scale, height: pixels.height * scale)
                RegionCanvas(regions: $s.editRegions, edit: true, interactive: s.regionDrawing)
                  .frame(width: fitted.width, height: fitted.height)
                  .position(x: geo.size.width / 2, y: geo.size.height / 2)
              }
            }
          }
          .padding(22)
      } else {
        VStack(spacing: 12) {
          Image(systemName: "photo.badge.plus").font(.system(size: 28)).foregroundStyle(P.muted)
          Cap(text: "перетащите картинку, которую править", rule: false)
          Text("или нажмите «Редактировать» на готовой картинке во вкладке «изображение»")
            .font(.sans(12)).foregroundStyle(P.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(over ? P.accent.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { s.pickEditSource() }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .dropDestination(for: DroppedPicture.self) { items, _ in
      guard let url = items.lazy.compactMap({ $0.fileURL }).first else { return false }
      s.setEditSource(url)
      return true
    } isTargeted: { over = $0 }
    .overlay {
      if mine, !(s.showProgressPreview && s.livePreview != nil) { WorkingBadge(s: s) }
    }
    .overlay(alignment: .topTrailing) {
      HStack(spacing: 8) {
        if s.editSource != nil, s.editResult != nil, !mine {
          if s.editShowResult {
            FloatButton(symbol: "arrow.uturn.backward", title: "ИСХОДНИК") {
              s.editShowResult = false
            }
            FloatButton(symbol: "pencil.and.outline", title: "ПРАВИТЬ ДАЛЬШЕ") {
              s.useResultAsSource()
            }
            .help("сделать этот результат новым исходником")
          } else {
            FloatButton(symbol: "photo", title: "РЕЗУЛЬТАТ") { s.editShowResult = true }
          }
        }
        GalleryButton(s: s)
      }
      .padding(16)
    }
    .background(P.panel2)
  }
}
/// The picture with the mask over it, painted with the mouse. The mask is kept as a grey
/// bitmap at the picture's size (capped at 2048) and handed back when a stroke ends.
@available(macOS 26, *)
struct MaskCanvas: NSViewRepresentable {
  let url: URL
  @Binding var mask: CGImage?
  let brush: Double
  let erasing: Bool

  func makeNSView(context: Context) -> MaskCanvasView {
    let view = MaskCanvasView()
    view.onChange = { mask = $0 }
    return view
  }

  func updateNSView(_ view: MaskCanvasView, context: Context) {
    view.onChange = { mask = $0 }
    view.brush = brush
    view.erasing = erasing
    view.show(url: url, mask: mask)
  }
}
@available(macOS 26, *)
final class MaskCanvasView: NSView {
  var onChange: ((CGImage?) -> Void)?
  var brush: Double = 0.05 { didSet { needsDisplay = true } }
  var erasing = false
  private var image: NSImage?
  private var shownURL: URL?
  private var bitmap: CGContext?
  /// The mask last handed out, to tell a change from outside (cleared, inverted) from an echo.
  private var emitted: CGImage?
  private var last: CGPoint?
  private var pointer: CGPoint?

  override var isFlipped: Bool { false }
  override var acceptsFirstResponder: Bool { true }

  func show(url: URL, mask: CGImage?) {
    if url != shownURL {
      shownURL = url
      image = NSImage(contentsOf: url)
      let size = Studio.pixelSize(of: url) ?? (1024, 1024)
      bitmap = CGContext(
        data: nil, width: size.width, height: size.height, bitsPerComponent: 8,
        bytesPerRow: size.width, space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGImageAlphaInfo.none.rawValue)
      emitted = nil
      load(mask)
    } else if mask !== emitted {
      load(mask)
    }
    needsDisplay = true
  }

  private func load(_ mask: CGImage?) {
    guard let bitmap else { return }
    let rect = CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height)
    bitmap.setFillColor(gray: 0, alpha: 1)
    bitmap.fill(rect)
    if let mask { bitmap.draw(mask, in: rect) }
    emitted = mask
  }

  /// Where the picture sits: fitted into the view, centred.
  private var imageRect: CGRect {
    guard let image, image.size.width > 0, image.size.height > 0 else { return bounds }
    let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
    let w = image.size.width * scale
    let h = image.size.height * scale
    return CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
  }

  private var radiusOnScreen: CGFloat {
    let rect = imageRect
    return CGFloat(brush) * min(rect.width, rect.height)
  }

  override func draw(_ dirtyRect: NSRect) {
    let rect = imageRect
    image?.draw(in: rect)
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    if let bitmap, let maskImage = bitmap.makeImage() {
      ctx.saveGState()
      ctx.clip(to: rect, mask: maskImage)
      ctx.setFillColor(NSColor.systemRed.withAlphaComponent(0.45).cgColor)
      ctx.fill(rect)
      ctx.restoreGState()
    }
    if let pointer, rect.contains(pointer) {
      let r = radiusOnScreen
      ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
      ctx.setLineWidth(1.5)
      ctx.strokeEllipse(in: CGRect(x: pointer.x - r, y: pointer.y - r, width: r * 2, height: r * 2))
      ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.5).cgColor)
      ctx.setLineWidth(0.5)
      ctx.strokeEllipse(
        in: CGRect(x: pointer.x - r - 1.5, y: pointer.y - r - 1.5, width: r * 2 + 3, height: r * 2 + 3))
    }
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(
      NSTrackingArea(
        rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
        owner: self))
  }

  override func mouseMoved(with event: NSEvent) {
    pointer = convert(event.locationInWindow, from: nil)
    needsDisplay = true
  }

  override func mouseExited(with event: NSEvent) {
    pointer = nil
    needsDisplay = true
  }

  override func mouseDown(with event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    last = p
    // Option held: the eraser for as long as it is held
    paint(from: p, to: p, erase: erasing || event.modifierFlags.contains(.option))
  }

  override func mouseDragged(with event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    pointer = p
    paint(from: last ?? p, to: p, erase: erasing || event.modifierFlags.contains(.option))
    last = p
  }

  override func mouseUp(with event: NSEvent) {
    last = nil
    let made = bitmap?.makeImage()
    emitted = made
    onChange?(made)
  }

  private func paint(from a: CGPoint, to b: CGPoint, erase: Bool) {
    guard let bitmap else { return }
    let rect = imageRect
    guard rect.width > 0, rect.height > 0 else { return }
    func toBitmap(_ p: CGPoint) -> CGPoint {
      CGPoint(
        x: (p.x - rect.minX) / rect.width * CGFloat(bitmap.width),
        y: (p.y - rect.minY) / rect.height * CGFloat(bitmap.height))
    }
    let radius = CGFloat(brush) * CGFloat(min(bitmap.width, bitmap.height))
    bitmap.setStrokeColor(gray: erase ? 0 : 1, alpha: 1)
    bitmap.setFillColor(gray: erase ? 0 : 1, alpha: 1)
    bitmap.setLineWidth(radius * 2)
    bitmap.setLineCap(.round)
    let start = toBitmap(a)
    let end = toBitmap(b)
    if start == end {
      bitmap.fillEllipse(in: CGRect(x: start.x - radius, y: start.y - radius, width: radius * 2, height: radius * 2))
    } else {
      bitmap.move(to: start)
      bitmap.addLine(to: end)
      bitmap.strokePath()
    }
    needsDisplay = true
  }
}
/// Brush, eraser and the rest of the mask's controls.
@available(macOS 26, *)
struct MaskTools: View {
  @ObservedObject var s: Studio

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      // FLUX.3 klein can be told where things are with boxes instead of a painted mask
      if s.regionsAvailable {
        Segmented(
          options: [(false, "маска"), (true, "рамки")],
          value: Binding(get: { s.regionDrawing }, set: { s.regionDrawing = $0 }), fill: true)
      }
      if s.regionsAvailable, s.regionDrawing {
        RegionsBlock(s: s)
      } else {
        maskBody
      }
    }
  }

  private var maskBody: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Cap(text: "маска")
        Spacer()
        if !s.maskIsEmpty {
          Button { s.clearMask() } label: {
            Text("очистить").font(.mono(9, .bold)).tracking(0.8).foregroundStyle(P.muted)
          }
          .buttonStyle(.plain)
        }
      }
      HStack(spacing: 8) {
        Segmented(
          options: [(false, "кисть"), (true, "ластик")],
          value: Binding(get: { s.maskErasing }, set: { s.maskErasing = $0 }))
          .fixedSize()
        SmallButton(title: "инвертировать") { s.invertMask() }
          .disabled(s.editSource == nil)
        Spacer(minLength: 0)
      }
      HStack(spacing: 8) {
        Text("размер").font(.mono(9)).foregroundStyle(P.muted)
        Slider(value: $s.maskBrush, in: 0.005...0.2).tint(P.accent).controlSize(.small)
      }
      Toggle(isOn: $s.maskFresh) {
        Text("рисовать заново, не глядя на то, что там").font(.mono(9)).foregroundStyle(P.ink)
      }
      .toggleStyle(.checkbox).controlSize(.small)
      Text(
        s.maskIsEmpty
          ? "закрасьте на картинке место, которое надо перерисовать. без маски меняется вся картинка. ⌥ — ластик"
          : "перерисуется только закрашенное; остальное останется как было"
      )
      .font(.mono(9)).tracking(0.3).foregroundStyle(P.muted)
      .fixedSize(horizontal: false, vertical: true)
    }
  }
}
/// img2img strength, for models that do not edit by instruction.
@available(macOS 26, *)
struct EditStrengthRow: View {
  @ObservedObject var s: Studio

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Cap(text: "сила изменения")
        Spacer()
        Text(String(format: "%.0f%%", s.editStrength * 100)).font(.mono(10, .semibold))
          .foregroundStyle(P.ink).monospacedDigit()
      }
      Slider(value: $s.editStrength, in: 0.05...1).tint(P.accent).controlSize(.small)
      Text("эта модель не правит по описанию: она перерисовывает картинку. меньше — ближе к исходнику")
        .font(.mono(9)).tracking(0.3).foregroundStyle(P.muted)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}
/// Phrases the person saved for edits: a click adds one to the prompt.
@available(macOS 26, *)
struct PhrasesRow: View {
  @ObservedObject var s: Studio

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Text("свои фразы").font(.mono(9)).tracking(0.3).foregroundStyle(P.muted)
        Spacer()
        Button { s.savePhrase() } label: {
          Text("+ СОХРАНИТЬ ПРОМПТ").font(.mono(9, .bold)).tracking(0.6).foregroundStyle(P.ink)
        }
        .buttonStyle(.plain)
        .disabled(s.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .help("запомнить то, что сейчас в Prompt, кнопкой ниже")
      }
      if !s.editPhrases.isEmpty {
        FlowRow(spacing: 6) {
          ForEach(s.editPhrases, id: \.self) { phrase in
            Button { s.addToPrompt(phrase) } label: {
              Text(phrase).font(.mono(9, .bold)).tracking(0.3).foregroundStyle(P.ink)
                .lineLimit(1).truncationMode(.tail)
                .padding(.horizontal, 8).frame(height: 22)
                .frame(maxWidth: 300)
                .background(P.panel)
                .overlay(Rectangle().stroke(P.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help(phrase)
            .contextMenu { Button("Удалить", role: .destructive) { s.removePhrase(phrase) } }
          }
        }
      }
    }
  }
}
/// Lays chips out in lines, wrapping like text.
struct FlowRow: Layout {
  var spacing: CGFloat = 6

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? .infinity
    var x: CGFloat = 0
    var y: CGFloat = 0
    var line: CGFloat = 0
    var widest: CGFloat = 0
    for view in subviews {
      let size = view.sizeThatFits(.unspecified)
      if x > 0, x + size.width > width {
        y += line + spacing
        x = 0
        line = 0
      }
      x += size.width + spacing
      line = max(line, size.height)
      widest = max(widest, x - spacing)
    }
    return CGSize(width: min(width, widest), height: y + line)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var x = bounds.minX
    var y = bounds.minY
    var line: CGFloat = 0
    for view in subviews {
      let size = view.sizeThatFits(.unspecified)
      if x > bounds.minX, x + size.width > bounds.maxX {
        y += line + spacing
        x = bounds.minX
        line = 0
      }
      view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
      x += size.width + spacing
      line = max(line, size.height)
    }
  }
}
/// ControlNets for the model's family, each with its settings and its control picture.
@available(macOS 26, *)
struct ControlNetBlock: View {
  @ObservedObject var s: Studio

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Cap(text: "ControlNet")
        Spacer()
        LilSwitch(isOn: $s.controlNetOn).scaleEffect(0.75)
      }
      if s.controlNetOn {
        ForEach(s.controlPicks) { pick in
          ControlPickRow(s: s, pick: pick)
        }
        SmallButton(title: "+ добавить ControlNet") { s.addControl() }
        Text("берёт форму, позу или контуры с исходника и держит их при перерисовке")
          .font(.mono(9)).tracking(0.3).foregroundStyle(P.muted)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}
@available(macOS 26, *)
struct ControlPickRow: View {
  @ObservedObject var s: Studio
  let pick: ControlPick

  private func change(_ edit: (inout ControlPick) -> Void) {
    var changed = pick
    edit(&changed)
    s.updateControl(changed)
  }

  var body: some View {
    let item = s.controlItem(pick)
    let hint = s.controlHint(pick)
    let missing = s.missingFiles(pick)
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Menu {
          ForEach(s.controlItems) { option in
            Button(option.file == pick.file ? "✓  " + option.name : option.name) {
              change { $0.file = option.file }
            }
          }
        } label: {
          DropLabel(title: item?.name ?? pick.file)
        }
        .menuStyle(.button).buttonStyle(.plain)
        .fixedSize(horizontal: false, vertical: true)
        Button { s.removeControl(pick) } label: {
          Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(P.muted)
        }
        .buttonStyle(.plain)
      }
      if item?.union == true {
        Menu {
          ForEach(ControlNets.unionHints, id: \.self) { option in
            Button(ControlNets.label(for: option)) { change { $0.unionHint = option } }
          }
        } label: {
          DropLabel(title: "читает: " + ControlNets.label(for: pick.unionHint))
        }
        .menuStyle(.button).buttonStyle(.plain)
        .fixedSize(horizontal: false, vertical: true)
      }

      if !missing.isEmpty {
        let fractions = missing.compactMap { s.controlDownloads[$0] }
        if fractions.isEmpty {
          SmallButton(title: "скачать: " + missing.joined(separator: ", "), strong: true) {
            s.downloadControl(pick)
          }
        } else {
          ProgressView(value: fractions.reduce(0, +) / Double(fractions.count))
            .tint(P.accent).controlSize(.small)
        }
      }

      switch ControlNets.input(for: hint) {
      case .picture:
        PicturePick(
          title: "готовая картинка: \(ControlNets.label(for: hint))", picture: pick.picture,
          pick: { s.setControlPicture(pick, $0) })
      case .depth:
        PicturePick(
          title: "карта глубины (без неё глубину посчитает модель глубины)",
          picture: pick.picture, pick: { s.setControlPicture(pick, $0) })
      case .references:
        Text("читает «ещё картинки» выше").font(.mono(9)).foregroundStyle(P.muted)
      case .source:
        Text("читает \(ControlNets.label(for: hint)) с исходника").font(.mono(9))
          .foregroundStyle(P.muted)
      }

      HStack(spacing: 8) {
        Text("сила").font(.mono(9)).foregroundStyle(P.muted).frame(width: 46, alignment: .leading)
        Slider(value: Binding(get: { pick.weight }, set: { v in change { $0.weight = v } }), in: 0...2)
          .tint(P.accent).controlSize(.small)
        Text(String(format: "%.2f", pick.weight)).font(.mono(9)).monospacedDigit()
          .frame(width: 34, alignment: .trailing)
      }
      HStack(spacing: 8) {
        Text("с — по").font(.mono(9)).foregroundStyle(P.muted).frame(width: 46, alignment: .leading)
        Slider(value: Binding(get: { pick.start }, set: { v in change { $0.start = min(v, pick.end) } }), in: 0...1)
          .tint(P.accent).controlSize(.small)
        Slider(value: Binding(get: { pick.end }, set: { v in change { $0.end = max(v, pick.start) } }), in: 0...1)
          .tint(P.accent).controlSize(.small)
      }
      Text(String(format: "действует с %.0f%% до %.0f%% шагов", pick.start * 100, pick.end * 100))
        .font(.mono(9)).foregroundStyle(P.muted)
    }
    .padding(10)
    .background(P.panel)
    .overlay(Rectangle().stroke(P.hair, lineWidth: 1))
  }
}
/// A small slot for one picture: dropped, or picked with a click.
@available(macOS 26, *)
struct PicturePick: View {
  let title: String
  let picture: Reference?
  let pick: (URL?) -> Void

  var body: some View {
    HStack(spacing: 8) {
      if let picture {
        Image(nsImage: picture.thumb).resizable().scaledToFill()
          .frame(width: 40, height: 40).clipped()
          .overlay(Rectangle().stroke(P.line, lineWidth: 1))
        Button { pick(nil) } label: {
          Text("убрать").font(.mono(9, .bold)).foregroundStyle(P.muted)
        }
        .buttonStyle(.plain)
      } else {
        Button {
          let panel = NSOpenPanel()
          panel.allowedContentTypes = [.image]
          if panel.runModal() == .OK { pick(panel.urls.first) }
        } label: {
          Image(systemName: "plus").font(.system(size: 10, weight: .bold)).foregroundStyle(P.muted)
            .frame(width: 40, height: 40)
            .overlay(Rectangle().stroke(P.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dropDestination(for: DroppedPicture.self) { items, _ in
          guard let url = items.lazy.compactMap({ $0.fileURL }).first else { return false }
          pick(url)
          return true
        }
      }
      Text(title).font(.mono(9)).foregroundStyle(P.muted)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}
/// Every finer setting the engine has for this model, under one fold: each starts at what the
/// model recommends, a changed one is marked, and all of them go back with one button.
@available(macOS 26, *)
struct TweaksBlock: View {
  @ObservedObject var s: Studio
  let entry: InstalledModel?
  let masked: Bool

  private var _open = SwiftUI.State(initialValue: false)
  private var open: Bool {
    get { _open.wrappedValue }
    nonmutating set { _open.wrappedValue = newValue }
  }

  init(s: Studio, entry: InstalledModel?, masked: Bool) {
    self.s = s
    self.entry = entry
    self.masked = masked
  }

  var body: some View {
    if let entry, let traits = s.traits(for: entry, masked: masked) {
      let tweaks = Tweaks.visible(for: traits)
      let changed = tweaks.filter { s.isTweakChanged($0, for: entry) }.count
      VStack(alignment: .leading, spacing: 10) {
        Button { open.toggle() } label: {
          HStack(spacing: 6) {
            Image(systemName: open ? "chevron.down" : "chevron.right")
              .font(.system(size: 9, weight: .bold))
            Text("ЕЩЁ НАСТРОЙКИ").font(.mono(9, .bold)).tracking(1)
            Text(changed > 0 ? "· изменено \(changed)" : "· \(tweaks.count)")
              .font(.mono(9)).foregroundStyle(changed > 0 ? P.ink : P.muted)
            Spacer()
          }
          .foregroundStyle(P.ink)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if open {
          ForEach(tweaks) { tweak in
            if tweak.parent.map({ parent in
              tweaks.first { $0.id == parent }.map { s.tweakValue($0, for: entry) > 0 } ?? false
            }) ?? true {
              TweakRow(s: s, entry: entry, tweak: tweak)
                .padding(.leading, tweak.parent == nil ? 0 : 12)
            }
          }
          if changed > 0 {
            SmallButton(title: "вернуть как советует модель") { s.resetTweaks(for: entry) }
          }
          if s.tweakDefaults[entry.file] == nil {
            Text("значения модели появятся, когда движок её откроет")
              .font(.mono(9)).foregroundStyle(P.muted)
          }
        }
      }
    }
  }
}
@available(macOS 26, *)
struct TweakRow: View {
  @ObservedObject var s: Studio
  let entry: InstalledModel
  let tweak: Tweak

  var body: some View {
    let value = s.tweakValue(tweak, for: entry)
    let changed = s.isTweakChanged(tweak, for: entry)
    HStack(spacing: 8) {
      HStack(spacing: 5) {
        if changed { Circle().fill(P.accent).frame(width: 5, height: 5) }
        Text(tweak.title).font(.mono(10)).foregroundStyle(P.ink)
          .fixedSize(horizontal: false, vertical: true)
        InfoDot(text: tweak.hint)
      }
      Spacer(minLength: 6)
      switch tweak.kind {
      case .toggle:
        LilSwitch(
          isOn: Binding(get: { value > 0 }, set: { s.setTweak(tweak, $0 ? 1 : 0, for: entry) })
        )
        .scaleEffect(0.7)
      case .number(let range, _, let decimals):
        if decimals == 0 {
          NumberField(
            value: Binding(
              get: { Int(value) },
              set: { s.setTweak(tweak, min(max(Double($0), range.lowerBound), range.upperBound), for: entry) }))
          .frame(width: 70)
        } else {
          DecimalField(
            value: Binding(get: { value }, set: { s.setTweak(tweak, $0, for: entry) }), range: range)
          .frame(width: 70)
        }
      case .choice(let options):
        Menu {
          ForEach(options, id: \.value) { option in
            Button(option.value == value ? "✓  " + option.label : option.label) {
              s.setTweak(tweak, option.value, for: entry)
            }
          }
        } label: {
          DropLabel(title: options.first { $0.value == value }?.label ?? "—")
        }
        .menuStyle(.button).buttonStyle(.plain)
        .fixedSize()
      }
    }
  }
}
