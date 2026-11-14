import AVKit
import MediaGenerationKit
import SwiftUI
import Translation
import UniformTypeIdentifiers

/// Everything the next run will use, plus what it costs, along the bottom of the window.
@available(macOS 26, *)
struct StatusBar: View {
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
        Button { s.openModels() } label: {
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
        Button { s.openModels() } label: {
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
struct GalleryButton: View {
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
struct Gallery: View {
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
/// The light chip that floats over the picture.
@available(macOS 26, *)
struct FloatButton: View {
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
/// Shown until the engine is on the machine. It is a separate program, so the app says so
/// plainly instead of pretending to work.
@available(macOS 26, *)
struct FirstRun: View {
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
/// Problems as cards in the corner: what happened, and the buttons that deal with it.
@available(macOS 26, *)
struct NoticeStack: View {
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
      s.showSettings = true
    case .openModels:
      s.openModels()
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
