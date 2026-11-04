import AVKit
import MediaGenerationKit
import SwiftUI
import Translation
import UniformTypeIdentifiers

/// Settings from elsewhere: a picture dropped in (its metadata, or what Civitai keeps for it),
/// or the pictures people posted on Civitai for a model.
@available(macOS 26, *)
struct SettingsFinder: View {
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
struct FoundSummary: View {
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
struct CivitaiStatsView: View {
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
struct SideLock: View {
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
struct FitSizeButton: View {
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
