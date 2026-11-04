import AVKit
import MediaGenerationKit
import SwiftUI
import Translation
import UniformTypeIdentifiers

@available(macOS 26, *)
struct ContentView: View {
  @ObservedObject var s: Studio
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    ZStack {
      P.bg.ignoresSafeArea()
      if !s.engineHost.installed {
        FirstRun(s: s)
      } else {
      VStack(spacing: 0) {
        TopBar(s: s)
        Divider().overlay(P.line)
        HStack(spacing: 0) {
          Sidebar(s: s)
          Divider().overlay(P.line)
          Stage(s: s)
        }
        Divider().overlay(P.line)
        StatusBar(s: s)
      }
      }
      if let f = s.fullscreen {
        Fullscreen(frame: f, position: s.position(of: f)) { s.fullscreen = nil }
      }
    }
    .overlay(alignment: .bottomTrailing) {
      NoticeStack(s: s).padding(.trailing, 18).padding(.bottom, 44)
    }
    .translationTask(s.translator.configuration) { session in
      await s.translator.fulfill(with: session)
    }
    .sheet(isPresented: $s.showGallery) { Gallery(s: s) }
    .dropDestination(for: URL.self) { urls, _ in
      let files = urls.filter {
        ["safetensors", "ckpt", "pt", "pth"].contains($0.pathExtension.lowercased())
      }
      guard !files.isEmpty else {
        // A picture: from Finder a file, from a browser its web address, fetched here.
        let pictures = urls.filter {
          !$0.isFileURL || (UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) ?? false)
        }
        guard !pictures.isEmpty else { return false }
        Task { @MainActor in
          for url in pictures {
            if url.isFileURL {
              s.acceptDropped(url)
            } else if let local = try? await DroppedPicture.download(url) {
              s.acceptDropped(local)
            } else {
              s.status = "картинка по ссылке не скачалась"
            }
          }
        }
        return true
      }
      s.library.add(files)
      openWindow(id: "models")
      return true
    }
    .task { s.warmUp() }
    .animation(.easeOut(duration: 0.2), value: s.pro)
    .frame(minWidth: 1100, minHeight: 700)
    .lilAppearance()
    // the system focus ring is drawn above everything, fullscreen included, and lags behind
    // controls whose width changes
    .focusEffectDisabled()
  }
}
@available(macOS 26, *)
private struct TopBar: View {
  @ObservedObject var s: Studio

  var body: some View {
    HStack(spacing: 0) {
      HStack(spacing: 0) {
        Wordmark().fixedSize()
        Spacer(minLength: 10)
        Segmented(options: Tab.allCases.map { ($0, $0.label) }, value: $s.tab)
          .fixedSize()
      }
      .padding(.leading, 18)
      .frame(width: 392, alignment: .leading)

      Spacer(minLength: 12)
      MemoryChip(s: s)
      SettingsButton(s: s).padding(.leading, 6)
    }
    .padding(.trailing, 16)
    .frame(height: 46)
    .background(P.panel)
  }
}
@available(macOS 26, *)
struct Wordmark: View {
  var body: some View {
    Text(text).tracking(0.5).lineLimit(1).fixedSize()
  }

  /// One attributed string, not three stacked Texts: ART carries the weight, IFICIAL the
  /// lighter grey, and the whole thing shares a single baseline.
  private var text: AttributedString {
    var lil = AttributedString("LIL ")
    lil.font = .sans(19, .bold)
    lil.foregroundColor = P.ink
    var art = AttributedString("ART")
    art.font = .sans(19, .bold)
    art.foregroundColor = P.ink
    var rest = AttributedString("IFICIAL")
    rest.font = .sans(19)
    rest.foregroundColor = P.muted
    return lil + art + rest
  }
}
@available(macOS 26, *)
private struct MemoryChip: View {
  @ObservedObject var s: Studio
  @ObservedObject var monitor: SystemMonitor

  init(s: Studio) {
    self.s = s
    self.monitor = s.monitor
  }

  private var label: String {
    let now = monitor.now
    var parts = [String(format: "%.1f ГБ", now.usedByUsGB)]
    if let gpu = now.gpuLoad { parts.append("GPU \(Int((gpu * 100).rounded()))%") }
    if let temperature = now.chipTemp { parts.append("\(Int(temperature.rounded()))°") }
    return parts.joined(separator: " · ")
  }

  var body: some View {
    Button { s.showMemory.toggle() } label: {
      HStack(spacing: 7) {
        Image(systemName: "memorychip").font(.system(size: 11))
        Text(label).font(.mono(10, .semibold)).tracking(0.4).monospacedDigit()
      }
      .foregroundStyle(P.ink)
      .frame(minWidth: 176)
      .padding(.horizontal, 10).frame(height: 30)
      .background(P.panel2)
      .overlay(Rectangle().stroke(P.line, lineWidth: 1))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("Память, нагрузка и температура")
    .popover(isPresented: $s.showMemory, arrowEdge: .bottom) {
      MemoryPopover(s: s, monitor: s.monitor).frame(width: 300)
    }
  }
}
@available(macOS 26, *)
private struct MemoryPopover: View {
  @ObservedObject var s: Studio
  @ObservedObject var monitor: SystemMonitor

  private func percent(_ value: Double?) -> String? {
    value.map { "\(Int(($0 * 100).rounded()))%" }
  }
  private func watts(_ value: Double?) -> String? {
    value.map { String(format: "%.1f Вт", $0) }
  }
  private func joined(_ parts: String?...) -> String {
    let text = parts.compactMap { $0 }.joined(separator: " · ")
    return text.isEmpty ? "—" : text
  }

  var body: some View {
    let now = monitor.now
    VStack(alignment: .leading, spacing: 10) {
      Cap(text: "память", rule: false)
      SpecRow(k: "движок", v: String(format: "%.1f ГБ", now.engineGB))
      SpecRow(k: "приложение", v: String(format: "%.1f ГБ", now.appGB))
      SpecRow(k: "свободно", v: String(format: "%.1f из %.0f ГБ", now.freeGB, Mem.machineGB))
      SpecRow(
        k: "держать модель в памяти",
        v: s.cacheGB > 0 ? String(format: "%.0f ГБ", s.cacheGB) : "нет")

      Cap(text: "нагрузка", rule: false).padding(.top, 4)
      SpecRow(k: "CPU", v: joined(percent(now.cpuLoad), watts(now.cpuWatts)))
      SpecRow(k: "GPU", v: joined(percent(now.gpuLoad), watts(now.gpuWatts)))
      SpecRow(k: "NPU", v: joined(watts(now.aneWatts)))

      Cap(text: "температура", rule: false).padding(.top, 4)
      SpecRow(k: "чип", v: now.chipTemp.map { String(format: "%.0f °C", $0) } ?? "—")

      HWButton(title: "Освободить память") { s.unload() }
        .padding(.top, 4)
    }
    .padding(16)
    .background(P.panel)
  }
}
@available(macOS 26, *)
private struct SettingsButton: View {
  @ObservedObject var s: Studio
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    // A second click closes the window the first one opened. Whether it is open is asked of
    // the window itself: SwiftUI does not always report a window closed with its red button,
    // and a flag kept by hand then stayed "open" forever and the gear could only close.
    Button {
      if let window = Self.settingsWindow, window.isVisible {
        window.performClose(nil)
      } else {
        openWindow(id: "settings")
      }
    } label: {
      Image(systemName: "gearshape")
        .font(.system(size: 13))
        .foregroundStyle(P.ink)
        .frame(width: 30, height: 30)
        .background(P.panel2)
        .overlay(Rectangle().stroke(P.line, lineWidth: 1))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("Настройки  ⌘,")
  }

  private static var settingsWindow: NSWindow? {
    NSApp.windows.first {
      $0.identifier?.rawValue.hasPrefix("settings") == true || $0.title == "Настройки"
    }
  }
}
@available(macOS 26, *)
private struct VideoSidebar: View {
  @ObservedObject var s: Studio

  var body: some View {
    VStack(alignment: .leading, spacing: 15) {
      if s.videoModels.isEmpty {
        NoVideoModels(s: s)
      } else {
        VideoModelRow(s: s)
        RefinerRow(s: s)
        SpeedRow(s: s)
        FrameBox(s: s, slot: .first)
        // the last frame only shows where it means something, or once one has been sent here
        if s.videoTakesLastFrame || s.videoLastFrame != nil { FrameBox(s: s, slot: .last) }
        RecentStills(
          s: s,
          caption: s.videoTakesLastFrame
            ? "недавние изображения · нажмите — первый кадр, правая кнопка — последний"
            : "недавние изображения · нажмите, чтобы сделать первым кадром",
          pick: { s.setFrame($0, .first) },
          options: [
            ("Первым кадром", { s.setFrame($0, .first) }),
            ("Последним кадром", { s.setFrame($0, .last) }),
          ],
          chosen: { url in s.videoFirstFrame?.url == url || s.videoLastFrame?.url == url })
        PromptBox(s: s)
        if !s.videoFixedLength { LengthRow(s: s) }
        QualityRow(s: s)
        if s.videoPro { VideoProSizeBlock(s: s) } else { VideoSizeRow(s: s) }
        if s.videoPro { VideoProBlock(s: s) }
        VideoSummary(s: s)
      }
    }
  }
}
@available(macOS 26, *)
private struct NoVideoModels: View {
  @ObservedObject var s: Studio
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Cap(text: "видео")
      Text("видеомоделей пока нет")
        .font(.sans(13)).foregroundStyle(P.ink)
      Text(
        "начните с Wan 2.1 1.3B — она весит 1.6 ГБ и делает пятисекундные ролики. "
          + "текстовый кодировщик к ней качается один раз и потом общий для всех моделей Wan."
      )
      .font(.mono(10)).tracking(0.2).foregroundStyle(P.muted)
      .fixedSize(horizontal: false, vertical: true)
      HWButton(title: "Открыть каталог", primary: true) {
        s.library.catalogTab = true
        s.catalog.kind = nil
        s.catalog.videoOnly = true
        openWindow(id: "models")
      }
    }
  }
}
/// A frame of the clip: the first one an image-to-video model animates, or the last one a
/// first-and-last-frame model should arrive at.
///
/// Big enough to drop a photo onto and obvious enough to find, because on half the video
/// models the first frame is not an extra — it is the input.
@available(macOS 26, *)
private struct FrameBox: View {
  @ObservedObject var s: Studio
  let slot: FrameSlot

  private var _over = SwiftUI.State(initialValue: false)
  private var over: Bool {
    get { _over.wrappedValue }
    nonmutating set { _over.wrappedValue = newValue }
  }

  init(s: Studio, slot: FrameSlot) {
    self.s = s
    self.slot = slot
  }

  private var used: Bool { slot == .first ? s.videoTakesImage : s.videoTakesLastFrame }
  private var picked: Reference? { s.frame(slot) }

  private var note: (text: String, warning: Bool) {
    switch slot {
    case .first:
      if s.takesImageOverridden {
        return used
          ? ("с него начнётся ролик — вы отметили, что модель принимает картинку", false)
          : ("не отправится — вы отметили, что модель рисует только по Prompt", true)
      }
      return used
        ? ("с него начнётся ролик", false)
        : ("по описанию модель рисует только по Prompt — если это не так, отметьте ниже", true)
    case .last:
      if !used { return ("эта модель последний кадр не примет — в каталоге его умеет только MiniMax H3", true) }
      if s.videoFirstFrame == nil { return ("нужен и первый кадр: ролик идёт от одного к другому", true) }
      return ("к нему ролик придёт", false)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Cap(text: used ? slot.label : slot.label + " · не нужен")
        Spacer()
        if slot == .first {
          // the person knows the model; the app only guesses from its description
          Button { s.setTakesImage(s.takesImageOverridden ? nil : !s.videoTakesImage) } label: {
            Text(
              s.takesImageOverridden ? "как в описании" : (used ? "модель не берёт картинку" : "модель берёт картинку")
            )
            .font(.mono(9, .bold)).tracking(0.6).foregroundStyle(used ? P.muted : P.accentText)
          }
          .buttonStyle(.plain)
          .help("отметить самому, принимает ли эта модель первый кадр (I2V)")
        }
        if picked != nil {
          Button { s.clearFrame(slot) } label: {
            Text("убрать").font(.mono(9, .bold)).tracking(0.8).foregroundStyle(P.muted)
          }
          .buttonStyle(.plain)
        }
      }

      if let picked {
        HStack(spacing: 10) {
          Image(nsImage: picked.thumb)
            .resizable().scaledToFill()
            .frame(width: 92, height: 56).clipped()
            .overlay(Rectangle().stroke(P.line, lineWidth: 1))
          VStack(alignment: .leading, spacing: 4) {
            Text(picked.url.lastPathComponent)
              .font(.mono(10)).foregroundStyle(P.ink).lineLimit(1).truncationMode(.middle)
            Text(note.text)
              .font(.mono(9)).tracking(0.2)
              .foregroundStyle(note.warning ? P.accent : P.muted)
              .fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: 0)
        }
      } else {
        Button { s.pickFrame(slot) } label: {
          VStack(spacing: 5) {
            Image(systemName: "photo").font(.system(size: 15)).foregroundStyle(P.muted)
            Text(used ? "перетащите картинку или нажмите" : "необязательно")
              .font(.mono(9)).tracking(0.3).foregroundStyle(P.muted)
          }
          .frame(maxWidth: .infinity).frame(height: 64)
          .background(over ? P.accent.opacity(0.12) : P.panel2)
          .overlay(
            Rectangle().stroke(
              over ? P.accent : P.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }

      if slot == .first, used, picked == nil {
        Text("без картинки эта модель тоже работает — считает ролик по одному Prompt")
          .font(.mono(9)).tracking(0.3).foregroundStyle(P.ink.opacity(0.35))
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .dropDestination(for: DroppedPicture.self) { items, _ in
      guard let url = items.lazy.compactMap({ $0.fileURL }).first else { return false }
      s.setFrame(url, slot)
      return true
    } isTargeted: { over = $0 }
  }
}
/// Pictures made earlier, one click from going wherever this strip is for.
@available(macOS 26, *)
private struct RecentStills: View {
  @ObservedObject var s: Studio
  let caption: String
  /// What a click does.
  let pick: (URL) -> Void
  /// Everything the right mouse button offers besides "Показать в Finder".
  let options: [(title: String, action: (URL) -> Void)]
  let chosen: (URL) -> Bool

  var body: some View {
    if !s.recentStills.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        Text(caption)
          .font(.mono(9)).tracking(0.3).foregroundStyle(P.muted)
          .fixedSize(horizontal: false, vertical: true)
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 6) {
            ForEach(s.recentStills) { still in
              Button { pick(still.url) } label: {
                Image(nsImage: still.thumb)
                  .resizable().scaledToFill()
                  .frame(width: 64, height: 40).clipped()
                  .overlay(
                    Rectangle().stroke(
                      chosen(still.url) ? P.accent : P.line,
                      lineWidth: chosen(still.url) ? 2 : 1))
              }
              .buttonStyle(.plain)
              .help(still.url.lastPathComponent)
              .contextMenu {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                  Button(option.title) { option.action(still.url) }
                }
                Divider()
                Button("Показать в Finder") {
                  NSWorkspace.shared.activateFileViewerSelecting([still.url])
                }
              }
            }
          }
        }
      }
    }
  }
}
/// Everything an editing model needs: the picture to change, up to three to borrow from,
/// and a nudge on how to ask. Appears by itself when the chosen model can edit.
@available(macOS 26, *)
private struct EditBox: View {
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
private struct PictureNumber: View {
  let number: Int

  var body: some View {
    Text("\(number)")
      .font(.mono(9, .bold)).foregroundStyle(P.accentInk)
      .frame(width: 16, height: 16)
      .background(P.accent)
  }
}
@available(macOS 26, *)
private struct VideoModelRow: View {
  @ObservedObject var s: Studio
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Cap(text: "модель")
      HStack(spacing: 8) {
        Menu {
          ForEach(s.videoModels) { m in
            Button {
              s.selectVideoModel(m.file)
            } label: {
              Text(m.file == s.videoModel ? "✓  " + m.name : m.name)
              Text([m.familyLabel, m.sizeLabel].filter { !$0.isEmpty }.joined(separator: " · "))
            }
          }
          Divider()
          Button("Модели…") { openWindow(id: "models") }
        } label: {
          DropLabel(
            title: s.videoModels.first(where: { $0.file == s.videoModel })?.name
              ?? "выберите модель",
            strong: true)
        }
        .menuStyle(.button).buttonStyle(.plain)
        .fixedSize(horizontal: false, vertical: true)

        FinderButton(s: s)

        ProToggle(isOn: $s.videoPro)
      }
    }
    .sheet(isPresented: $s.showSettingsFinder) { SettingsFinder(s: s) }
  }
}
/// The magnifier beside a model: settings from a picture or from Civitai.
@available(macOS 26, *)
private struct FinderButton: View {
  @ObservedObject var s: Studio

  var body: some View {
    Button { s.showSettingsFinder = true } label: {
      Image(systemName: "text.magnifyingglass").font(.system(size: 12))
        .foregroundStyle(P.ink)
        .frame(width: 34, height: 34)
        .background(P.panel)
        .overlay(Rectangle().stroke(P.line, lineWidth: 1))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("найти настройки: из картинки или на Civitai")
  }
}
/// Distilled or full. Two words that decide whether the numbers below make sense.
@available(macOS 26, *)
private struct SpeedRow: View {
  @ObservedObject var s: Studio

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      Cap(text: "тип модели")
      Segmented(
        options: SpeedProfile.allCases.map { ($0, $0.label) },
        value: Binding(get: { s.speedProfile }, set: { s.setSpeed($0) }), fill: true)
      Text(s.speedProfile.hint)
        .font(.mono(9)).tracking(0.3).foregroundStyle(P.muted)
    }
  }
}
@available(macOS 26, *)
private struct LengthRow: View {
  @ObservedObject var s: Studio

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack {
        Cap(text: "длительность")
        Spacer()
        Text(s.videoLengthLabel).font(.mono(10, .semibold)).foregroundStyle(P.ink)
          .monospacedDigit()
      }
      Slider(
        value: $s.videoSeconds, in: 1...max(1.5, s.videoFamily?.maxSeconds ?? 5)
      )
      .tint(P.accent).controlSize(.small)
    }
  }
}
/// The quality slider. It moves steps, because steps are what quality actually is here.
@available(macOS 26, *)
private struct QualityRow: View {
  @ObservedObject var s: Studio

  private var range: ClosedRange<Double> { s.speedProfile.stepRange }

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack {
        Cap(text: "качество")
        Spacer()
        Text("\(s.videoSteps) шагов").font(.mono(10, .semibold)).foregroundStyle(P.ink)
          .monospacedDigit()
      }
      Slider(
        value: Binding(
          get: { Double(s.videoSteps) },
          set: { s.videoSteps = Int($0.rounded()) }), in: range, step: 1
      )
      .tint(P.accent).controlSize(.small)
      Text(
        s.speedProfile == .fast
          ? "быстрой модели больше шагов не нужно — она на это и училась"
          : "меньше шагов — быстрее и грубее, больше — дольше и ровнее"
      )
      .font(.mono(9)).tracking(0.3).foregroundStyle(P.muted)
      .fixedSize(horizontal: false, vertical: true)
    }
  }
}
@available(macOS 26, *)
private struct VideoSizeRow: View {
  @ObservedObject var s: Studio

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Cap(text: "размер")
      Menu {
        ForEach(Array(s.videoSizes.enumerated()), id: \.offset) { index, size in
          Button(size.label) { s.videoSizeIndex = index }
        }
      } label: {
        DropLabel(title: s.videoSize.label, strong: true)
      }
      .menuStyle(.button).buttonStyle(.plain)
      .fixedSize(horizontal: false, vertical: true)
      Text("размеры те, на которых модель обучалась")
        .font(.mono(9)).tracking(0.3).foregroundStyle(P.ink.opacity(0.35))
    }
  }
}
@available(macOS 26, *)
private struct VideoSummary: View {
  @ObservedObject var s: Studio

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      SpecRow(k: "получится", v: "\(s.videoSize.width) × \(s.videoSize.height)")
      SpecRow(k: "займёт", v: s.videoTimeEstimate)
      SpecRow(k: "памяти", v: String(format: "~%.0f ГБ", s.videoMemoryGB))
    }
  }
}
/// Everything the PRO checkbox reveals on the video tab.
@available(macOS 26, *)
private struct VideoProBlock: View {
  @ObservedObject var s: Studio

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Cap(text: "Negative prompt")
        Spacer()
        LilSwitch(isOn: $s.videoNegativeOn).scaleEffect(0.75)
      }
      if s.videoNegativeOn {
        TextEditor(text: $s.videoNegative)
          .textEditorStyle(.plain).font(.sans(12)).scrollContentBackground(.hidden)
          .padding(10).frame(height: 56)
          .background(P.panel2).overlay(Rectangle().stroke(P.line, lineWidth: 1))
      }

      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 7) {
          Cap(text: "CFG")
          DecimalField(
            value: Binding(get: { Double(s.videoCFG) }, set: { s.videoCFG = Float($0) }),
            range: 0...30)
        }
        VStack(alignment: .leading, spacing: 7) {
          Cap(text: "Shift")
          DecimalField(
            value: Binding(get: { Double(s.videoShift) }, set: { s.videoShift = Float($0) }),
            range: 0...20)
        }
        VStack(alignment: .leading, spacing: 7) {
          Cap(text: "кадров в секунду")
          NumberField(value: Binding(
            get: { s.videoFPS }, set: { s.videoFPS = max(1, min(60, $0)) }))
        }
      }
      Text("shift растягивает расписание шума: выше — плавнее движение, ниже — резче")
        .font(.mono(9)).tracking(0.3).foregroundStyle(P.muted)
        .fixedSize(horizontal: false, vertical: true)

      VStack(alignment: .leading, spacing: 7) {
        Cap(text: "Sampler")
        Menu {
          ForEach(Samplers.all, id: \.0) { item in
            Button(item.1) { s.videoSampler = item.0 }
          }
        } label: {
          DropLabel(title: Samplers.name(s.videoSampler), strong: true)
        }
        .menuStyle(.button).buttonStyle(.plain)
        .fixedSize(horizontal: false, vertical: true)
      }

      PartsBlock(s: s, entry: s.videoEntry, strong: true)
      TweaksBlock(s: s, entry: s.videoEntry, masked: false)

      VStack(alignment: .leading, spacing: 7) {
        Cap(text: "формат файла")
        Menu {
          ForEach(VideoWriter.Format.allCases, id: \.self) { format in
            Button(format.label) { s.videoFormat = format }
          }
        } label: {
          DropLabel(title: s.videoFormat.label, strong: true)
        }
        .menuStyle(.button).buttonStyle(.plain)
        .fixedSize(horizontal: false, vertical: true)
      }

      SeedRow(s: s)
    }
  }
}
@available(macOS 26, *)
private struct Stage: View {
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
/// The video stage: the clip itself, looping, with what it cost underneath.
@available(macOS 26, *)
private struct VideoStage: View {
  @ObservedObject var s: Studio

  private var mine: Bool { s.busy && s.running == .video }

  var body: some View {
    VStack(spacing: 0) {
      ZStack {
        P.panel2
        if let live = s.livePreview, mine, s.showProgressPreview {
          Image(nsImage: live)
            .resizable().interpolation(.medium).scaledToFit()
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(P.line.opacity(0.5), lineWidth: 1))
            .overlay(alignment: .topLeading) {
              HStack(spacing: 6) {
                Circle().fill(Color(hex: 0xff2d2d)).frame(width: 7, height: 7)
                Text("ПЕРВЫЙ КАДР · " + s.stepText.uppercased())
                  .font(.mono(9, .bold)).tracking(1)
              }
              .foregroundStyle(.white)
              .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
              .padding(12)
            }
            .padding(22)
        } else if let clip = s.selectedClip {
          VStack(spacing: 12) {
            ClipPlayer(player: s.clipPlayer)
              .aspectRatio(
                CGFloat(clip.width) / CGFloat(max(1, clip.height)), contentMode: .fit)
              .clipShape(RoundedRectangle(cornerRadius: 6))
              .overlay(
                RoundedRectangle(cornerRadius: 6).stroke(P.line.opacity(0.5), lineWidth: 1))
            HStack(spacing: 16) {
              Text(clip.lengthLabel)
              Text(clip.sizeLabel)
              if clip.restored {
                Text("из папки с результатами")
              } else {
                Text("Seed \(clip.seed)")
                Text("\(clip.steps) шагов")
                Text("сделано за " + Budget.humanTime(clip.took))
              }
            }
            .font(.mono(9)).tracking(0.4).foregroundStyle(P.muted)
          }
          .padding(22)
        } else if !mine {
          VStack(spacing: 14) {
            Cap(text: "здесь появится видео", rule: false)
            Text("напишите Prompt и нажмите «Сгенерировать»")
              .font(.sans(13)).foregroundStyle(P.muted)
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .overlay {
        if mine, !(s.showProgressPreview && s.livePreview != nil) {
          WorkingBadge(s: s)
        }
      }
      .overlay(alignment: .topTrailing) {
        if let clip = s.selectedClip, !s.busy {
          FloatButton(symbol: "folder", title: "ПОКАЗАТЬ ФАЙЛ") {
            NSWorkspace.shared.activateFileViewerSelecting([clip.url])
          }
          .padding(16)
        }
      }

      if !s.clips.isEmpty { ClipStrip(s: s) }
    }
    .background(P.panel2)
  }
}
/// The player itself.
///
/// Not SwiftUI's `VideoPlayer`: in this build it aborts the whole app the moment it is
/// laid out. Its shim framework fails to resolve the superclass metadata of the view it
/// wraps — the same kind of trouble as `@State` being a macro here, and for the same
/// reason: the app is compiled without full Xcode. The AppKit player underneath has no
/// such problem and brings real transport controls with it.
@available(macOS 26, *)
private struct ClipPlayer: NSViewRepresentable {
  let player: AVPlayer

  func makeNSView(context: Context) -> AVPlayerView {
    let view = AVPlayerView()
    view.player = player
    view.controlsStyle = .inline
    view.videoGravity = .resizeAspect
    view.showsFullScreenToggleButton = false
    return view
  }

  func updateNSView(_ view: AVPlayerView, context: Context) {
    if view.player !== player { view.player = player }
  }
}
/// The clips made this session, newest first.
@available(macOS 26, *)
private struct ClipStrip: View {
  @ObservedObject var s: Studio

  var body: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 8) {
        ForEach(s.clips) { clip in
          Button { s.show(clip) } label: {
            Image(nsImage: clip.poster)
              .resizable().interpolation(.medium).scaledToFill()
              .frame(width: 96, height: 56).clipped()
              .overlay(alignment: .bottomLeading) {
                Text(String(format: "%.1f с", clip.duration))
                  .font(.mono(8, .bold)).foregroundStyle(.white)
                  .padding(.horizontal, 4).padding(.vertical, 2)
                  .background(Color.black.opacity(0.55))
                  .padding(4)
              }
              .overlay(
                Rectangle().stroke(
                  clip.id == s.selectedClip?.id ? P.accent : P.line,
                  lineWidth: clip.id == s.selectedClip?.id ? 2 : 1))
          }
          .buttonStyle(.plain)
        }
      }
      .padding(12)
    }
    .frame(height: 82)
    .background(P.panel)
    .overlay(Rectangle().frame(height: 1).foregroundStyle(P.line), alignment: .top)
  }
}
/// While a picture is being made and its in-between steps are hidden: a calm strip instead of
/// noise.
@available(macOS 26, *)
private struct WorkingBadge: View {
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
private struct Finder: View {
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
private struct Checkerboard: View {
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
private struct HUD: View {
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
private struct Brackets: View {
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
private struct Fullscreen: View {
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
/// Everything the next run will use, plus what it costs, along the bottom of the window.
@available(macOS 26, *)
private struct StatusBar: View {
  @ObservedObject var s: Studio
  @Environment(\.openWindow) private var openWindow

  private var video: Bool { s.tab == .video }

  private var memoryColour: Color {
    let verdict =
      video
      ? Budget.verdict(needGB: s.videoMemoryGB, freeGB: s.systemFree + s.footprint)
      : s.memoryVerdict
    switch verdict {
    case .fine: return P.muted
    case .tight: return P.amber
    case .tooMuch: return P.accent
    }
  }

  var body: some View {
    HStack(spacing: 14) {
      LED(color: s.busy ? P.accent : P.led)
      Text(s.busy ? (s.stepText.isEmpty ? "работает" : s.stepText) : s.status)
        .font(.mono(9, .bold)).tracking(1).foregroundStyle(P.ink)
      if s.queued > 0 {
        Text("в очереди \(s.queued)").font(.mono(9)).tracking(0.6).foregroundStyle(P.muted)
      }
      if let job = s.library.activeJob {
        Rectangle().fill(P.hair).frame(width: 1, height: 14)
        Button { openWindow(id: "models") } label: {
          Text(
            "ДОБАВЛЯЮ \(job.name.uppercased()) · \(job.stage.label.uppercased())"
              + (job.progress > 0 ? " \(Int(job.progress * 100))%" : ""))
            .font(.mono(9, .bold)).tracking(0.6).foregroundStyle(P.accentText)
            .lineLimit(1).truncationMode(.middle)
        }
        .buttonStyle(.plain)
        .help("Открыть окно «Модели»")
      } else if let failed = s.library.jobs.first(where: { $0.failure != nil }) {
        Rectangle().fill(P.hair).frame(width: 1, height: 14)
        Button { openWindow(id: "models") } label: {
          Text("НЕ ПОЛУЧИЛОСЬ: \(failed.name.uppercased())")
            .font(.mono(9, .bold)).tracking(0.6).foregroundStyle(P.accentText)
            .lineLimit(1).truncationMode(.middle)
        }
        .buttonStyle(.plain)
        .help("Причина — в окне «Модели»")
      }

      Rectangle().fill(P.hair).frame(width: 1, height: 14)

      Text(video ? s.videoRunLine : s.runLine)
        .font(.mono(9)).tracking(0.5).foregroundStyle(P.muted)
        .lineLimit(1).truncationMode(.tail)

      Spacer(minLength: 12)

      Text(String(format: "~%.1f ГБ", video ? s.videoMemoryGB : s.memoryEstimateGB))
        .font(.mono(9, .semibold)).foregroundStyle(memoryColour)
      Text(video ? s.videoTimeEstimate : s.timeEstimate)
        .font(.mono(9, .semibold)).foregroundStyle(P.ink)
      if !s.translator.note.isEmpty {
        Rectangle().fill(P.hair).frame(width: 1, height: 14)
        Text(s.translator.note)
          .font(.mono(9)).tracking(0.3).foregroundStyle(P.muted)
          .lineLimit(1).truncationMode(.tail).frame(maxWidth: 220, alignment: .trailing)
      }
    }
    .padding(.horizontal, 16)
    .frame(height: 30)
    .background(P.panel)
  }
}
/// Sits over the picture rather than stealing a band of the window.
@available(macOS 26, *)
private struct GalleryButton: View {
  @ObservedObject var s: Studio

  var body: some View {
    Button { s.showGallery = true } label: {
      HStack(spacing: 7) {
        Image(systemName: "square.grid.2x2").font(.system(size: 11))
        Text("ГАЛЕРЕЯ").font(.mono(9, .bold)).tracking(1.2)
        if !s.frames.isEmpty {
          Text("\(s.frames.count)").font(.mono(9)).foregroundStyle(P.muted)
        }
      }
      .foregroundStyle(P.ink)
      .padding(.horizontal, 11).frame(height: 30)
      .background(P.panel.opacity(0.72))
      .overlay(RoundedRectangle(cornerRadius: 8).stroke(P.line.opacity(0.35), lineWidth: 1))
      .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    .buttonStyle(.plain)
  }
}
@available(macOS 26, *)
private struct Gallery: View {
  @ObservedObject var s: Studio

  private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Cap(text: "галерея · \(s.frames.count)", rule: false, color: P.ink)
        Spacer()
        HWButton(title: "Показать в Finder") { s.openOutputFolder() }
        HWButton(title: "закрыть") { s.showGallery = false }
      }
      .padding(16)
      .background(P.panel)
      .overlay(Rectangle().frame(height: 1).foregroundStyle(P.line), alignment: .bottom)

      if s.frames.isEmpty {
        VStack { Spacer(); Cap(text: "пока пусто", rule: false); Spacer() }
      } else {
        ScrollView {
          LazyVGrid(columns: columns, spacing: 12) {
            ForEach(s.frames) { f in
              Image(nsImage: f.image)
                .resizable().scaledToFill()
                .frame(height: 150).clipped()
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                  RoundedRectangle(cornerRadius: 6)
                    .stroke(s.selected?.id == f.id ? P.accent : P.hair, lineWidth: 1)
                )
                .onTapGesture(count: 2) { s.fullscreen = f; s.showGallery = false }
                .onTapGesture { s.selected = f; s.showGallery = false }
                .contextMenu {
                  Button("Редактировать") { s.showGallery = false; s.edit(f) }
                  Button("Анимировать первым кадром") { s.showGallery = false; s.animate(f, as: .first) }
                  Button("Анимировать последним кадром") { s.showGallery = false; s.animate(f, as: .last) }
                  Divider()
                  Button("Показать в Finder") { s.reveal(f) }
                }
            }
          }
          .padding(16)
        }
      }
    }
    .frame(width: 820, height: 560)
    .background(P.bg)
  }
}
/// Pictures handed to the model along with the words.
@available(macOS 26, *)
private struct ReferenceRow: View {
  @ObservedObject var s: Studio

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Cap(text: "изображения на входе")
        Spacer()
        Button { s.addReference() } label: {
          Image(systemName: "plus").font(.system(size: 10, weight: .bold))
            .foregroundStyle(P.ink)
            .frame(width: 26, height: 22)
            .background(P.panel)
            .overlay(Rectangle().stroke(P.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
      }

      if s.references.isEmpty {
        Text("необязательно · исходник для перерисовки, маска или референс стиля")
          .font(.mono(9)).tracking(0.3).foregroundStyle(P.muted)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        VStack(spacing: 8) {
          ForEach(s.references) { r in
            HStack(spacing: 10) {
              Image(nsImage: r.thumb)
                .resizable().scaledToFill()
                .frame(width: 42, height: 42).clipped()
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(P.hair, lineWidth: 1))

              VStack(alignment: .leading, spacing: 4) {
                Menu {
                  ForEach(RefRole.allCases, id: \.self) { role in
                    Button(role.label) { s.setRole(r, role) }
                  }
                } label: {
                  HStack(spacing: 5) {
                    Text(r.role.label.uppercased()).font(.mono(9, .bold)).tracking(1)
                    Image(systemName: "chevron.down").font(.system(size: 7))
                  }
                  .foregroundStyle(P.ink)
                  .padding(.horizontal, 7).padding(.vertical, 4)
                  .background(P.panel2)
                  .overlay(Rectangle().stroke(P.line, lineWidth: 1))
                }
                .menuStyle(.button).buttonStyle(.plain)
                .fixedSize()

                Text(r.role.hint)
                  .font(.mono(8)).tracking(0.2).foregroundStyle(P.muted)
                  .lineLimit(2).fixedSize(horizontal: false, vertical: true)
              }

              Spacer(minLength: 4)

              Button { s.removeReference(r) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                  .foregroundStyle(P.muted)
                  .frame(width: 22, height: 22)
              }
              .buttonStyle(.plain)
            }
            .padding(8)
            .background(P.panel)
            .overlay(Rectangle().stroke(P.hair, lineWidth: 1))
          }
        }

        if s.hasSourceImage {
          VStack(alignment: .leading, spacing: 6) {
            HStack {
              Cap(text: "Denoise", rule: false)
              Spacer()
              Text(String(format: "%.2f", s.strength))
                .font(.mono(10, .semibold)).foregroundStyle(P.ink)
            }
            Slider(
              value: Binding(get: { Double(s.strength) }, set: { s.strength = Float($0) }),
              in: 0.1...1
            )
            .tint(P.accent).controlSize(.small)
            Text("ниже — ближе к исходнику, выше — свободнее")
              .font(.mono(9)).tracking(0.3).foregroundStyle(P.muted)
          }
        }
      }
    }
  }
}
/// Sizes people reach for, so nobody has to remember that 832×1216 is the portrait one.
@available(macOS 26, *)
private struct SizePresetRow: View {
  @ObservedObject var s: Studio

  private let columns = [GridItem(.adaptive(minimum: 74), spacing: 6)]

  var body: some View {
    LazyVGrid(columns: columns, spacing: 6) {
      ForEach(Array(SizePreset.allCases.enumerated()), id: \.offset) { _, p in
        let on = (s.proWidth, s.proHeight) == p.size
        Button {
          s.proWidth = p.size.0
          s.proHeight = p.size.1
          s.widthText = String(p.size.0)
          s.heightText = String(p.size.1)
        } label: {
          Text(p.label)
            .font(.mono(9, on ? .bold : .regular))
            .foregroundStyle(on ? P.accentInk : P.muted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(on ? P.accent : P.panel)
            .overlay(Rectangle().stroke(on ? P.accent : P.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
      }
    }
  }
}
/// A labelled number box that keeps whatever is typed and only snaps on commit.
@available(macOS 26, *)
private struct SizeField: View {
  let label: String
  @Binding var text: String
  let commit: () -> Void

  var body: some View {
    HStack(spacing: 7) {
      Text(label).font(.mono(9, .bold)).foregroundStyle(P.muted)
      TextField("", text: $text)
        .textFieldStyle(.plain)
        .font(.mono(13, .semibold))
        .onSubmit(commit)
    }
    .padding(.horizontal, 9).padding(.vertical, 6)
    .background(P.panel2)
    .overlay(Rectangle().stroke(P.line, lineWidth: 1))
  }
}
/// The images a single run produced, all on screen together.
@available(macOS 26, *)
private struct BatchGrid: View {
  @ObservedObject var s: Studio

  private var columns: [GridItem] {
    let n = s.batchGroup.count <= 2 ? s.batchGroup.count : 2
    return Array(repeating: GridItem(.flexible(), spacing: 12), count: max(1, n))
  }

  var body: some View {
    LazyVGrid(columns: columns, spacing: 12) {
      ForEach(s.batchGroup) { f in
        Image(nsImage: f.image)
          .resizable().interpolation(.high).scaledToFit()
          .clipShape(RoundedRectangle(cornerRadius: 6))
          .overlay(
            RoundedRectangle(cornerRadius: 6)
              .stroke(s.selected?.id == f.id ? P.accent : P.line.opacity(0.5), lineWidth: 1))
          .onTapGesture(count: 2) { s.fullscreen = f }
          .onTapGesture { s.selected = f; s.gridMode = false }
      }
    }
  }
}
/// The light chip that floats over the picture.
@available(macOS 26, *)
private struct FloatButton: View {
  let symbol: String
  let title: String
  let tap: () -> Void

  var body: some View {
    Button(action: tap) {
      HStack(spacing: 7) {
        Image(systemName: symbol).font(.system(size: 11))
        Text(title).font(.mono(9, .bold)).tracking(1.2)
      }
      .foregroundStyle(P.ink)
      .padding(.horizontal, 11).frame(height: 30)
      .background(P.panel.opacity(0.72))
      .overlay(RoundedRectangle(cornerRadius: 8).stroke(P.line.opacity(0.35), lineWidth: 1))
      .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    .buttonStyle(.plain)
  }
}
/// Sends the picture on screen to the video tab. The click itself does the usual thing —
/// the first frame — and the arrow beside it offers the last one.
@available(macOS 26, *)
private struct AnimateButton: View {
  @ObservedObject var s: Studio
  let frame: Frame

  var body: some View {
    HStack(spacing: 0) {
      Button { s.animate(frame, as: .first) } label: {
        HStack(spacing: 7) {
          Image(systemName: "film").font(.system(size: 11))
          Text("АНИМИРОВАТЬ").font(.mono(9, .bold)).tracking(1.2)
        }
        .padding(.leading, 11).padding(.trailing, 9).frame(height: 30)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("отправить на вкладку видео первым кадром")

      Rectangle().fill(P.line.opacity(0.35)).frame(width: 1, height: 16)

      Menu {
        Button("Первым кадром") { s.animate(frame, as: .first) }
        Button("Последним кадром") { s.animate(frame, as: .last) }
      } label: {
        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
          .frame(width: 26, height: 30).contentShape(Rectangle())
      }
      .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
      .help("выбрать, каким кадром отправить")
    }
    .foregroundStyle(P.ink)
    .background(P.panel.opacity(0.72))
    .overlay(RoundedRectangle(cornerRadius: 8).stroke(P.line.opacity(0.35), lineWidth: 1))
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }
}
/// Shown until the engine is on the machine. It is a separate program, so the app says so
/// plainly instead of pretending to work.
@available(macOS 26, *)
private struct FirstRun: View {
  @ObservedObject var s: Studio

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Wordmark()
        Spacer()
      }
      .padding(.horizontal, 18)
      .frame(height: 46)
      .background(P.panel)
      .overlay(Rectangle().frame(height: 1).foregroundStyle(P.line), alignment: .bottom)

      Spacer()

      VStack(alignment: .leading, spacing: 18) {
        Cap(text: "нужен движок", rule: false, color: P.ink)

        Text("lil art рисует не сам")
          .font(.sans(22, .bold)).foregroundStyle(P.ink)

        Text(
          "Считает отдельная программа — движок Draw Things. Её надо скачать один раз, "
            + "около 200 МБ. Дальше она обновляется сама, и приложение ради этого "
            + "переустанавливать не придётся."
        )
        .font(.sans(13)).foregroundStyle(P.muted)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 460, alignment: .leading)

        Text("движок работает на вашем маке. промпты и изображения никуда не отправляются")
          .font(.mono(9)).tracking(0.3).foregroundStyle(P.muted)
          .fixedSize(horizontal: false, vertical: true)

        if s.engineHost.busy {
          VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: s.engineHost.progress).tint(P.accent).frame(width: 320)
            Text(s.engineHost.status).font(.mono(10)).foregroundStyle(P.ink)
          }
        } else {
          HStack(spacing: 10) {
            HWButton(title: "скачать движок", primary: true) {
              Task {
                await s.engineHost.checkLatest()
                await s.engineHost.install()
                s.engineHost.start(modelsDir: s.modelsDir)
              }
            }
            .frame(width: 240)
          }
          if !s.engineHost.status.isEmpty {
            Text(s.engineHost.status).font(.mono(10)).foregroundStyle(P.ink)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      .padding(40)

      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(P.bg)
  }
}
/// The upscaler switch and, when on, its settings. The same in the simple and the pro view.
@available(macOS 26, *)
private struct UpscaleSection: View {
  @ObservedObject var s: Studio

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Cap(text: "Upscaler")
        Spacer()
        LilSwitch(isOn: Binding(get: { s.upscaleOn }, set: { s.setUpscale($0) }))
          .scaleEffect(0.75)
      }
      if s.upscaleOn { UpscaleBlock(s: s) }
    }
  }
}
/// The engine's upscaler: runs right after the picture, in the same request.
@available(macOS 26, *)
private struct UpscaleBlock: View {
  @ObservedObject var s: Studio

  private var model: Upscalers.Model? { Upscalers.model(s.upscaler) }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Menu {
        ForEach(Upscalers.all, id: \.file) { item in
          Button {
            s.chooseUpscaler(item.file)
          } label: {
            Text(item.file == s.upscaler ? "✓  " + item.name : item.name)
            Text(
              "×\(item.native) · \(item.megabytes) МБ"
                + (s.library.installed.contains { $0.file == item.file } ? "" : " · скачается"))
          }
        }
      } label: {
        DropLabel(title: model?.name ?? s.upscaler)
      }
      .menuStyle(.button).buttonStyle(.plain)
      .fixedSize(horizontal: false, vertical: true)

      if let model {
        Text(model.hint)
          .font(.mono(9)).tracking(0.3).foregroundStyle(P.muted)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack(spacing: 8) {
        Text("МАСШТАБ").font(.mono(9)).tracking(0.8).foregroundStyle(P.muted)
        Segmented(
          options: [(2, "×2"), (4, "×4")],
          value: Binding(get: { s.effectiveFactor }, set: { s.upscaleFactor = $0 }))
          .fixedSize()
        Spacer()
        Text(s.upscaledSizeLabel).font(.mono(9)).foregroundStyle(P.muted).monospacedDigit()
      }

      if let job = s.upscaleJob {
        if let reason = job.failure {
          HStack(spacing: 8) {
            Text("Не скачался: " + reason)
              .font(.mono(9)).foregroundStyle(P.accentText)
              .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            SmallButton(title: "Повторить") { s.library.retry(job) }
          }
        } else {
          VStack(alignment: .leading, spacing: 5) {
            Text(job.stage == .waiting ? "В ОЧЕРЕДИ" : "СКАЧИВАЮ · \(Int(job.progress * 100))%")
              .font(.mono(9, .bold)).tracking(0.8).foregroundStyle(P.accentText)
            ProgressView(value: job.progress).tint(P.accent)
          }
        }
      } else if !s.upscalerReady {
        HWButton(title: "Скачать · \(model?.megabytes ?? 0) МБ") { s.ensureUpscaler() }
      }
    }
    .padding(10)
    .background(P.panel)
    .overlay(Rectangle().stroke(P.hair, lineWidth: 1))
  }
}
/// The LoRAs for the next run. Several at once, each with its own strength.
@available(macOS 26, *)
private struct LoRABlock: View {
  @ObservedObject var s: Studio
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if s.loraFiles.isEmpty {
        Text("LoRA пока нет. Перетащите .safetensors в окно или откройте «Модели»")
          .font(.mono(9)).tracking(0.3).foregroundStyle(P.muted)
          .fixedSize(horizontal: false, vertical: true)
        HWButton(title: "Модели…") { openWindow(id: "models") }
      } else {
        ForEach(s.loraPicks) { pick in
          LoRARow(s: s, pick: pick)
        }

        HStack(spacing: 8) {
          Button { s.addLoRA() } label: {
            HStack(spacing: 6) {
              Image(systemName: "plus").font(.system(size: 10, weight: .bold))
              Text("ДОБАВИТЬ LORA").font(.mono(9, .bold)).tracking(1)
            }
            .foregroundStyle(P.ink)
            .padding(.horizontal, 10).frame(height: 28)
            .background(P.panel)
            .overlay(Rectangle().stroke(P.line, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
          }
          .buttonStyle(.plain)

          Spacer()
        }

        Text("LoRA действует только на модели своего семейства. Отрицательная сила гасит её эффект")
          .font(.mono(9)).tracking(0.3).foregroundStyle(P.muted)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .onAppear {
      if s.loraPicks.isEmpty, !s.loraFiles.isEmpty { s.addLoRA() }
    }
  }
}
@available(macOS 26, *)
private struct LoRARow: View {
  @ObservedObject var s: Studio
  let pick: LoRAPick

  private var title: String {
    s.loraFiles.first { $0.file == pick.file }?.name ?? pick.file
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Menu {
          ForEach(s.loraFiles) { file in
            Button("\(file.name) · \(file.sizeLabel)") {
              s.setLoRA(pick, file: file.file)
            }
          }
        } label: {
          DropLabel(title: title)
        }
        .menuStyle(.button).buttonStyle(.plain)
        .fixedSize(horizontal: false, vertical: true)

        Button { s.removeLoRA(pick) } label: {
          Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            .foregroundStyle(P.muted)
            .frame(width: 34, height: 34)
            .background(P.panel)
            .overlay(Rectangle().stroke(P.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("убрать эту LoRA")
      }

      HStack(spacing: 10) {
        Text("СИЛА").font(.mono(9)).tracking(0.8).foregroundStyle(P.muted)
        Slider(
          value: Binding(get: { pick.weight }, set: { s.setLoRAWeight(pick, $0) }),
          in: -1...2, step: 0.05
        )
        .tint(P.accent).controlSize(.small)
        Text(String(format: "%.2f", pick.weight))
          .font(.mono(10, .semibold)).foregroundStyle(P.ink)
          .frame(width: 38, alignment: .trailing)
      }
    }
    .padding(10)
    .background(P.panel)
    .overlay(Rectangle().stroke(P.hair, lineWidth: 1))
  }
}
/// Keeps sampler, steps and cfg for the chosen model, or goes back to its recommendation.
@available(macOS 26, *)
private struct SaveForModelRow: View {
  @ObservedObject var s: Studio

  var body: some View {
    let current = Recommended(steps: s.proSteps, cfg: s.proCFG, sampler: s.sampler)
    let saved = s.savedForModel
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        if let saved, saved == current {
          HStack(spacing: 8) {
            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
              .foregroundStyle(P.led)
            Text("ЗАПОМНЕНО ДЛЯ МОДЕЛИ").font(.mono(10, .bold)).tracking(1.2)
              .foregroundStyle(P.ink)
          }
          .padding(.horizontal, 12).frame(height: 34)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(P.panel)
          .overlay(RoundedRectangle(cornerRadius: 9).stroke(P.hair, lineWidth: 1))
        } else {
          HWButton(title: saved == nil ? "Запомнить для модели" : "Запомнить изменения") {
            s.saveForModel()
          }
        }
        if saved != nil {
          Button { s.forgetForModel() } label: {
            Text("СБРОСИТЬ").font(.mono(9, .bold)).tracking(1).foregroundStyle(P.muted)
              .padding(.horizontal, 8).frame(height: 34)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
      }
      Text(
        saved == nil
          ? "Sampler, Steps и CFG запомнятся для этой модели и будут действовать и в простом режиме"
          : "для этой модели действуют ваши настройки, а не рекомендация"
      )
      .font(.mono(8)).tracking(0.2).foregroundStyle(P.muted)
      .fixedSize(horizontal: false, vertical: true)
    }
  }
}
/// Problems as cards in the corner: what happened, and the buttons that deal with it.
@available(macOS 26, *)
private struct NoticeStack: View {
  @ObservedObject var s: Studio
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    VStack(alignment: .trailing, spacing: 10) {
      ForEach(s.notices) { notice in
        VStack(alignment: .leading, spacing: 8) {
          HStack(alignment: .center, spacing: 8) {
            LED(color: P.accent)
            Text(notice.title.uppercased()).font(.mono(10, .bold)).tracking(1)
              .foregroundStyle(P.ink)
              .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button { s.dismiss(notice) } label: {
              Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                .foregroundStyle(P.muted)
                .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Закрыть")
          }
          if !notice.message.isEmpty {
            Text(notice.message).font(.sans(12)).foregroundStyle(P.ink)
              .fixedSize(horizontal: false, vertical: true)
          }
          if !notice.actions.isEmpty {
            HStack(spacing: 6) {
              ForEach(Array(notice.actions.enumerated()), id: \.offset) { index, choice in
                SmallButton(title: choice.title, strong: index == 0) {
                  perform(choice.action, notice)
                }
              }
            }
          }
        }
        .padding(12)
        .frame(width: 350, alignment: .leading)
        .background(P.panel)
        .overlay(Rectangle().stroke(P.line, lineWidth: 1))
        .background(Rectangle().fill(P.keyShadow.opacity(0.85)).offset(x: 4, y: 4))
        .transition(.move(edge: .trailing).combined(with: .opacity))
      }
    }
    .animation(.easeOut(duration: 0.2), value: s.notices.map(\.id))
  }

  private func perform(_ action: Notice.Action, _ notice: Notice) {
    switch action {
    case .openSettings(let page):
      s.settingsPage = page
      openWindow(id: "settings")
    case .openModels:
      openWindow(id: "models")
    case .useTranslator(let engine):
      s.translator.engine = engine
      s.translate()
    case .restartEngine:
      s.restartEngine()
    case .retryTranslation:
      s.translate()
    case .freeMemory:
      s.unload()
    }
    s.dismiss(notice)
  }
}
/// The middle of the edit tab: the picture being edited, big, with the mask painted over it;
/// or the latest result, with a way back and a way to keep editing it.
@available(macOS 26, *)
private struct EditStage: View {
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
private struct MaskCanvas: NSViewRepresentable {
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
private struct MaskTools: View {
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
private struct EditStrengthRow: View {
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
private struct PhrasesRow: View {
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
private struct FlowRow: Layout {
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
private struct ControlNetBlock: View {
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
private struct ControlPickRow: View {
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
private struct PicturePick: View {
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
private struct TweaksBlock: View {
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
private struct TweakRow: View {
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
/// Settings from elsewhere: a picture dropped in (its metadata, or what Civitai keeps for it),
/// or the pictures people posted on Civitai for a model.
@available(macOS 26, *)
private struct SettingsFinder: View {
  @ObservedObject var s: Studio
  @Environment(\.dismiss) private var dismiss

  private var _state = SwiftUI.State(initialValue: FinderState())
  private var state: FinderState {
    get { _state.wrappedValue }
    nonmutating set { _state.wrappedValue = newValue }
  }

  init(s: Studio) { self.s = s }

  struct FinderState {
    var found: FoundSettings?
    var foundNote = ""
    var takePrompt = true
    var query = ""
    var searching = false
    var models: [SettingsImport.CivitaiModel] = []
    var version: SettingsImport.CivitaiModel.Version?
    var modelName = ""
    var stats: SettingsImport.CivitaiStats?
    var note = ""
    var over = false
    var showOthers = false
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("НАЙТИ НАСТРОЙКИ").font(.mono(11, .bold)).tracking(1.2).foregroundStyle(P.ink)
        Spacer()
        Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction)
      }

      // from a picture
      VStack(alignment: .leading, spacing: 8) {
        Cap(text: "из картинки")
        Text(state.found == nil ? "перетащите сюда картинку из Civitai, ComfyUI, A1111 или Draw Things" : state.foundNote)
          .font(.sans(12)).foregroundStyle(P.muted)
          .frame(maxWidth: .infinity, minHeight: 64)
          .background(state.over ? P.accent.opacity(0.12) : P.panel2)
          .overlay(Rectangle().stroke(state.over ? P.accent : P.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
          .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            Task { await take(url) }
            return true
          } isTargeted: { state.over = $0 }
        if let found = state.found {
          VStack(alignment: .leading, spacing: 8) {
            Text("НАШЁЛ В КАРТИНКЕ · \(found.origin.uppercased())").font(.mono(10, .bold)).tracking(1)
              .foregroundStyle(P.accentText)
            FoundSummary(found: found)
            HStack {
              Toggle("взять и промпт", isOn: Binding(get: { state.takePrompt }, set: { state.takePrompt = $0 }))
                .toggleStyle(.checkbox).controlSize(.small)
              Spacer()
              SmallButton(title: "применить эти настройки", strong: true) {
                finish(found, prompt: state.takePrompt)
              }
            }
          }
          .padding(12)
          .overlay(Rectangle().stroke(P.accent, lineWidth: 1.5))
        }
      }

      // from Civitai
      VStack(alignment: .leading, spacing: 8) {
        Cap(text: "на civitai")
        HStack(spacing: 8) {
          TextField("название модели", text: Binding(get: { state.query }, set: { state.query = $0 }))
            .textFieldStyle(.plain).font(.mono(11))
            .padding(.horizontal, 9).frame(height: 30)
            .background(P.panel).overlay(Rectangle().stroke(P.line, lineWidth: 1))
            .onSubmit { Task { await search() } }
          SmallButton(title: state.searching ? "ищу…" : "искать", strong: true) { Task { await search() } }
            .disabled(state.searching || state.query.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        if !state.note.isEmpty {
          Text(state.note).font(.mono(9)).foregroundStyle(P.muted)
        }
        if let stats = state.stats, let version = state.version {
          // the answer first, plainly, with the question whether to use it
          VStack(alignment: .leading, spacing: 8) {
            Text("НАШЁЛ НАСТРОЙКИ").font(.mono(10, .bold)).tracking(1).foregroundStyle(P.accentText)
            Text("\(state.modelName) · \(version.name)").font(.sans(13, .bold)).foregroundStyle(P.ink)
            if stats.samples == 0 {
              Text("у картинок этой версии нет настроек — выберите другую ниже")
                .font(.mono(10)).foregroundStyle(P.muted)
            } else {
              CivitaiStatsView(stats: stats, version: version)
              HStack {
                Spacer()
                SmallButton(title: "применить эти настройки", strong: true) {
                  finish(typical(stats), prompt: false)
                }
              }
            }
          }
          .padding(12)
          .overlay(Rectangle().stroke(P.accent, lineWidth: 1.5))
        }
        if !state.models.isEmpty {
          Button { state.showOthers.toggle() } label: {
            HStack(spacing: 6) {
              Image(systemName: state.showOthers ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .bold))
              Text(state.stats == nil ? "нашлось моделей: \(state.models.count)" : "не та модель? другие совпадения")
                .font(.mono(9, .bold)).tracking(0.5)
              Spacer()
            }
            .foregroundStyle(P.ink).contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          if state.showOthers || state.stats == nil {
            ScrollView {
              VStack(alignment: .leading, spacing: 4) {
                ForEach(state.models) { model in
                  ForEach(model.versions.prefix(4)) { version in
                    Button { Task { await load(version, of: model.name) } } label: {
                      HStack {
                        Text(model.name).font(.sans(12, .bold)).foregroundStyle(P.ink).lineLimit(1)
                        Text(version.name).font(.mono(10)).foregroundStyle(P.muted).lineLimit(1)
                        Spacer()
                        Text(version.baseModel).font(.mono(9, .bold)).foregroundStyle(P.muted)
                      }
                      .padding(.horizontal, 8).padding(.vertical, 6)
                      .background(state.version?.id == version.id ? P.accent.opacity(0.15) : P.panel)
                      .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                  }
                }
              }
            }
            .frame(maxHeight: 180)
          }
        }
      }
    }
    .padding(20)
    .frame(width: 560)
    .background(P.bg)
    .onAppear {
      if state.query.isEmpty {
        let name = s.tab == .video ? (s.videoEntry?.name ?? s.videoModel) : (s.modelEntry?.name ?? s.model)
        state.query = ModelLibrary.pretty(ModelLibrary.withoutTechnicalTail(name.replacingOccurrences(of: ".ckpt", with: "")))
      }
    }
  }

  private func take(_ url: URL) async {
    state.foundNote = "читаю…"
    var local = url
    if !url.isFileURL {
      guard let downloaded = try? await DroppedPicture.download(url) else {
        // a Civitai page link rather than the picture itself
        if let id = SettingsImport.civitaiImageID(url), let found = try? await SettingsImport.civitaiImage(id) {
          show(found)
        } else {
          state.foundNote = "картинка по ссылке не скачалась"
        }
        return
      }
      local = downloaded
    }
    if let found = await s.settings(fromPicture: local, original: url) {
      show(found)
    } else {
      state.found = nil
      state.foundNote = "в этой картинке нет настроек: сайт мог их вырезать. Скачайте оригинал или поищите модель ниже"
    }
  }

  private func show(_ found: FoundSettings) {
    state.found = found
    state.foundNote = "нашёл: \(found.origin)"
  }

  private func search() async {
    let query = state.query.trimmingCharacters(in: .whitespaces)
    guard !query.isEmpty else { return }
    state.searching = true
    state.note = ""
    defer { state.searching = false }
    do {
      state.models = try await SettingsImport.civitaiSearch(query)
      state.stats = nil
      state.version = nil
      state.showOthers = false
      state.note = state.models.isEmpty ? "ничего не нашлось — попробуйте короче" : ""
    } catch {
      state.note = "Civitai не ответил: \(error.localizedDescription)"
      return
    }
    // the best match is opened at once, so the answer is on screen without another click
    if let model = state.models.first, let version = model.versions.first {
      await load(version, of: model.name)
    }
  }

  private func load(_ version: SettingsImport.CivitaiModel.Version, of model: String) async {
    state.note = "смотрю картинки к \(model) · \(version.name)…"
    do {
      state.stats = try await SettingsImport.civitaiStats(version: version.id)
      state.version = version
      state.modelName = model
      state.showOthers = false
      state.note = ""
    } catch {
      state.note = "Civitai не ответил: \(error.localizedDescription)"
    }
  }

  private func typical(_ stats: SettingsImport.CivitaiStats) -> FoundSettings {
    var found = FoundSettings(origin: "Civitai")
    found.sampler = stats.samplers.first?.name
    found.steps = SettingsImport.CivitaiStats.median(stats.steps)
    found.cfg = SettingsImport.CivitaiStats.median(stats.cfgs)
    found.clipSkip = SettingsImport.CivitaiStats.median(stats.clipSkips)
    return found
  }

  private func finish(_ found: FoundSettings, prompt: Bool) {
    let taken = s.apply(found, takePrompt: prompt)
    s.status = taken.isEmpty ? "настроек не нашлось" : "взял: " + taken.joined(separator: ", ")
    s.notify(
      Notice(
        title: taken.isEmpty ? "Настроек не нашлось" : "Настройки применены",
        message: taken.isEmpty
          ? "В найденном не оказалось ничего, что можно взять"
          : Studio.capitalized(taken.joined(separator: ", "))))
    dismiss()
  }
}
@available(macOS 26, *)
private struct FoundSummary: View {
  let found: FoundSettings

  var body: some View {
    let rows: [(String, String)] = [
      ("промпт", found.prompt ?? ""), ("негатив", found.negative ?? ""),
      ("шаги", found.steps.map(String.init) ?? ""), ("CFG", found.cfg.map { String(format: "%.1f", $0) } ?? ""),
      ("сэмплер", [found.sampler, found.scheduler].compactMap { $0 }.joined(separator: " / ")),
      ("seed", found.seed.map(String.init) ?? ""),
      ("размер", found.width.flatMap { w in found.height.map { "\(w)×\($0)" } } ?? ""),
      ("сила", found.strength.map { String(format: "%.2f", $0) } ?? ""),
      ("модель", found.model ?? ""),
    ].filter { !$0.1.isEmpty }
    VStack(alignment: .leading, spacing: 4) {
      ForEach(rows, id: \.0) { row in
        HStack(alignment: .top, spacing: 8) {
          Text(row.0).font(.mono(9)).foregroundStyle(P.muted).frame(width: 60, alignment: .leading)
          Text(row.1).font(.mono(10)).foregroundStyle(P.ink).lineLimit(3).textSelection(.enabled)
        }
      }
    }
    .padding(10).background(P.panel).overlay(Rectangle().stroke(P.hair, lineWidth: 1))
  }
}
@available(macOS 26, *)
private struct CivitaiStatsView: View {
  let stats: SettingsImport.CivitaiStats
  let version: SettingsImport.CivitaiModel.Version

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("\(stats.samples) картинок с настройками · \(version.baseModel)")
        .font(.mono(9)).foregroundStyle(P.muted)
      line("сэмплер", stats.samplers.prefix(3).map { "\($0.name) ×\($0.count)" }.joined(separator: ", "))
      line("шаги", spread(stats.steps.map(Double.init), decimals: 0))
      line("CFG", spread(stats.cfgs, decimals: 1))
      line("размер", stats.sizes.prefix(3).map { "\($0.size) ×\($0.count)" }.joined(separator: ", "))
      if !stats.clipSkips.isEmpty { line("clip skip", spread(stats.clipSkips.map(Double.init), decimals: 0)) }
      if !version.description.isEmpty {
        ScrollView {
          Text(version.description).font(.sans(11)).foregroundStyle(P.ink.opacity(0.8))
            .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        }
        .frame(maxHeight: 140)
        .padding(8).background(P.panel2)
      }
    }
    .padding(10).background(P.panel).overlay(Rectangle().stroke(P.hair, lineWidth: 1))
  }

  private func line(_ title: String, _ value: String) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Text(title).font(.mono(9)).foregroundStyle(P.muted).frame(width: 60, alignment: .leading)
      Text(value.isEmpty ? "—" : value).font(.mono(10)).foregroundStyle(P.ink)
    }
  }

  /// "обычно 25 (20–30)": the middle value and the middle half around it.
  private func spread(_ values: [Double], decimals: Int) -> String {
    guard !values.isEmpty else { return "" }
    let sorted = values.sorted()
    let f = "%.\(decimals)f"
    let mid = String(format: f, sorted[sorted.count / 2])
    let low = String(format: f, sorted[sorted.count / 4])
    let high = String(format: f, sorted[min(sorted.count - 1, sorted.count * 3 / 4)])
    return low == high ? mid : "обычно \(mid) (\(low)–\(high))"
  }
}
/// A lock beside a size field: that side stays put while the field is dragged.
@available(macOS 26, *)
private struct SideLock: View {
  @Binding var on: Bool
  let help: String

  var body: some View {
    Button { on.toggle() } label: {
      Image(systemName: on ? "lock.fill" : "lock.open")
        .font(.system(size: 10))
        .foregroundStyle(on ? P.accentInk : P.muted)
        .frame(width: 28, height: 28)
        .background(on ? P.accent : P.panel)
        .overlay(Rectangle().stroke(on ? P.accent : P.line, lineWidth: 1))
    }
    .buttonStyle(.plain)
    .help(help)
  }
}
/// Picks the size for the picture that was given: its own shape, at the size the model works
/// best at, in the engine's 64-pixel steps.
@available(macOS 26, *)
private struct FitSizeButton: View {
  @ObservedObject var s: Studio

  var body: some View {
    Button { s.fitSizeToPicture() } label: {
      HStack(spacing: 4) {
        Image(systemName: "aspectratio").font(.system(size: 9))
        Text("ПО КАРТИНКЕ").font(.mono(9, .bold)).tracking(0.6)
      }
      .foregroundStyle(P.ink)
      .padding(.horizontal, 7).frame(height: 24)
      .background(P.panel)
      .overlay(Rectangle().stroke(P.line, lineWidth: 1))
    }
    .buttonStyle(.plain)
    .help("подогнать размер под картинку: та же форма, оптимальный для модели размер")
  }
}
/// Wan 2.2's second expert: the low-noise model that finishes what the high-noise one began.
@available(macOS 26, *)
private struct RefinerRow: View {
  @ObservedObject var s: Studio

  var body: some View {
    if let entry = s.videoEntry {
      if s.videoRefinerInUse == nil, s.isLowExpert(entry), s.pairedHigh(for: entry) != nil {
        // the low one picked as the main model: the pair runs the other way round
        HStack(spacing: 8) {
          Text("это low-модель пары: начинать должна high")
            .font(.mono(9)).foregroundStyle(P.ink).fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 4)
          SmallButton(title: "поменять местами", strong: true) { s.swapExperts() }
        }
      } else if !s.videoRefinerChoices.isEmpty {
        VStack(alignment: .leading, spacing: 7) {
          Cap(text: "вторая модель (low)")
          Menu {
            Button(s.videoRefinerInUse == nil ? "✓  нет — одна модель" : "нет — одна модель") {
              s.setVideoRefiner("")
            }
            ForEach(s.videoRefinerChoices) { option in
              let paired = s.pairedLow(for: entry)?.file == option.file
              Button((option.file == s.videoRefiner ? "✓  " : "") + option.name + (paired ? "  · пара" : "")) {
                s.setVideoRefiner(option.file)
              }
            }
          } label: {
            DropLabel(title: s.videoRefinerInUse?.name ?? "нет — одна модель", strong: s.videoRefinerInUse != nil)
          }
          .menuStyle(.button).buttonStyle(.plain)
          .fixedSize(horizontal: false, vertical: true)
          if s.videoRefinerInUse != nil {
            let split = s.refinerSplit
            HStack {
              Text("переход на low").font(.mono(9)).foregroundStyle(P.muted)
              Spacer()
              Text("high \(split.high) · low \(split.low) шагов").font(.mono(10, .semibold))
                .foregroundStyle(P.ink).monospacedDigit()
            }
            Slider(
              value: Binding(get: { s.videoRefinerStart }, set: { s.setVideoRefinerStart($0) }),
              in: 0.02...0.6
            )
            .tint(P.accent).controlSize(.small)
            Text(
              "high рисует композицию и движение, low — детали. Wan 2.2 переходит на 10% шума для "
                + "картинки в видео и на 12.5% для текста; память — как у одной модели, движок выгружает первую"
            )
            .font(.mono(9)).tracking(0.3).foregroundStyle(P.muted)
            .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
    }
  }
}
/// The video size in PRO, the same field as for pictures: any width and height in 64-pixel
/// steps, with the model's own sizes one click away.
@available(macOS 26, *)
private struct VideoProSizeBlock: View {
  @ObservedObject var s: Studio

  private func widthBinding() -> Binding<Int> {
    Binding(get: { s.videoSize.width }, set: { s.setVideoCustomSize(width: $0, height: s.videoSize.height) })
  }

  private func heightBinding() -> Binding<Int> {
    Binding(get: { s.videoSize.height }, set: { s.setVideoCustomSize(width: s.videoSize.width, height: $0) })
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Cap(text: "размер")
        Spacer()
        if s.videoFirstFrame != nil {
          Button { s.fitVideoSizeToFrame() } label: {
            HStack(spacing: 4) {
              Image(systemName: "aspectratio").font(.system(size: 9))
              Text("ПО КАДРУ").font(.mono(9, .bold)).tracking(0.6)
            }
            .foregroundStyle(P.ink)
            .padding(.horizontal, 7).frame(height: 24)
            .background(P.panel)
            .overlay(Rectangle().stroke(P.line, lineWidth: 1))
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .help("подогнать размер под первый кадр: та же форма, столько же пикселей, сколько у модели")
        }
      }
      HStack(alignment: .top, spacing: 12) {
        SizePad(width: widthBinding(), height: heightBinding(), lockWidth: s.lockWidth, lockHeight: s.lockHeight)
          .frame(width: 186, height: 186)
        VStack(alignment: .leading, spacing: 7) {
          HStack(spacing: 6) {
            Text("Ш").font(.mono(9)).foregroundStyle(P.muted)
            NumberField(value: widthBinding()).frame(width: 62)
            SideLock(on: $s.lockWidth, help: "ширина не меняется, пока тянешь поле")
          }
          HStack(spacing: 6) {
            Text("В").font(.mono(9)).foregroundStyle(P.muted)
            NumberField(value: heightBinding()).frame(width: 62)
            SideLock(on: $s.lockHeight, help: "высота не меняется, пока тянешь поле")
          }
          Text(String(format: "%.2f мп", s.videoSize.megapixels)).font(.mono(9)).foregroundStyle(P.muted)
          Rectangle().fill(P.hair).frame(height: 1).padding(.vertical, 1)
          ForEach(Array(s.videoSizes.enumerated()), id: \.offset) { index, size in
            let on = s.videoCustomSize == nil && s.videoSizeIndex == index
            Button {
              s.videoCustomSize = nil
              s.videoSizeIndex = index
            } label: {
              Text(size.label)
                .font(.mono(9, on ? .bold : .regular))
                .foregroundStyle(on ? P.accentInk : P.muted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(on ? P.accent : P.panel)
                .overlay(Rectangle().stroke(on ? P.accent : P.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
          }
        }
      }
      Text("кнопками — размеры, на которых модель обучалась; полем — любой, шагами по 64")
        .font(.mono(9)).tracking(0.3).foregroundStyle(P.ink.opacity(0.35))
    }
  }
}


// MARK: - header






// MARK: - left sidebar













// MARK: - video





















// MARK: - stage











// MARK: - status bar, gallery, catalog



















// MARK: - edit tab













// MARK: - finding settings
