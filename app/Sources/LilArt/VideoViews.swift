import AVKit
import MediaGenerationKit
import SwiftUI
import Translation
import UniformTypeIdentifiers

@available(macOS 26, *)
struct VideoSidebar: View {
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
        if s.videoPro {
          HStack {
            Cap(text: "LoRA")
            Spacer()
            LilSwitch(isOn: $s.videoLoraOn).scaleEffect(0.75)
          }
          if s.videoLoraOn { LoRABlock(s: s, video: true) }
        }
        VideoSummary(s: s)
      }
    }
  }
}
@available(macOS 26, *)
struct NoVideoModels: View {
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
        s.openModels(openWindow)
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
struct FrameBox: View {
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
struct RecentStills: View {
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
@available(macOS 26, *)
struct VideoModelRow: View {
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
          Button("Модели…") { s.openModels(openWindow) }
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
struct FinderButton: View {
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
struct SpeedRow: View {
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
struct LengthRow: View {
  @ObservedObject var s: Studio

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack {
        Cap(text: "длительность")
        Spacer()
        Text(String(format: "%.1f с", Double(s.videoFrames) / Double(max(1, s.videoFPS))))
          .font(.mono(10, .semibold)).foregroundStyle(P.ink).monospacedDigit()
      }
      // two numbers instead of a slider: how many frames the model makes, and how fast they play
      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 7) {
          Cap(text: "кадров")
          NumberField(value: Binding(get: { s.videoFrames }, set: { s.setVideoFrames($0) }))
            .disabled(s.videoFixedLength)
        }
        VStack(alignment: .leading, spacing: 7) {
          Cap(text: "fps")
          NumberField(value: Binding(
            get: { s.videoFPS }, set: { s.videoFPS = max(1, min(60, $0)) }))
        }
      }
      if let fit = s.videoFramesThatFit {
        // the calculator: how long the clip may be before the Mac goes to disk
        HStack(spacing: 8) {
          Text(
            s.videoFrames > fit
              ? String(format: "нужно ~%.0f ГБ, без диска влезает до %d кадров", s.videoMemoryGB, fit)
              : String(format: "~%.0f ГБ · без диска влезает до %d кадров", s.videoMemoryGB, fit)
          )
          .font(.mono(9)).tracking(0.3)
          .foregroundStyle(s.videoFrames > fit ? P.accent : P.muted)
          .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 4)
          if s.videoFrames > fit {
            SmallButton(title: "вписать") { s.setVideoFrames(fit) }
          }
        }
      }
    }
  }
}
/// The quality slider. It moves steps, because steps are what quality actually is here.
@available(macOS 26, *)
struct QualityRow: View {
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
struct VideoSizeRow: View {
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
struct VideoSummary: View {
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
struct VideoProBlock: View {
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
/// The video stage: the clip itself, looping, with what it cost underneath.
@available(macOS 26, *)
struct VideoStage: View {
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
struct ClipPlayer: NSViewRepresentable {
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
struct ClipStrip: View {
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
/// Sends the picture on screen to the video tab. The click itself does the usual thing —
/// the first frame — and the arrow beside it offers the last one.
@available(macOS 26, *)
struct AnimateButton: View {
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
/// Wan 2.2's second expert: the low-noise model that finishes what the high-noise one began.
@available(macOS 26, *)
struct RefinerRow: View {
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
struct VideoProSizeBlock: View {
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
