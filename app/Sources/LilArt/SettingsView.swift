import SwiftUI

/// Settings (⌘,) in the studio's own look: a row of tabs like the main window's, one page per
/// subject below it.
@available(macOS 26, *)
struct SettingsView: View {
  @ObservedObject var s: Studio

  var body: some View {
    VStack(spacing: 0) {
      LilSettingsTabs(
        tabs: SettingsPage.allCases.map { ($0, $0.title, $0.symbol) },
        selection: $s.settingsPage)

      Group {
        switch s.settingsPage {
        case .general: GeneralSettings(s: s)
        case .prompt: PromptSettings(assist: s.assist)
        case .translation: TranslationSettings(translator: s.translator)
        case .engine: EngineSettings(s: s, engine: s.engineHost)
        case .look: LilAppearanceSettings()
        case .about:
          LilAboutSettings(
            description: "Рисует картинки и видео прямо на этом Mac, на движке Draw Things. "
              + "Картинки никуда не отправляются: в интернет программа ходит за моделями, словарями "
              + "тегов и обновлениями движка, а ещё — по вашему выбору — за переводом Google и настройками с Civitai.")
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    // six tabs: narrower and «О программе» no longer fits its button
    .frame(width: 680, height: 520)
    .lilAppearance()
    .focusEffectDisabled()
  }
}

@available(macOS 26, *)
private struct GeneralSettings: View {
  @ObservedObject var s: Studio

  var body: some View {
    LilSettingsPage {
      LilSettingRow(title: "Восстанавливать при запуске", note: "Модель, настройки, Prompt и LoRA — как при выходе") {
        LilSwitch(isOn: $s.restoreSession)
      }
      LilSettingRow(
        title: "Показывать процесс генерации",
        note: "Промежуточные шаги выглядят как шум и цветные пятна — так и должно быть. Без этого видна только полоса прогресса"
      ) {
        LilSwitch(isOn: $s.showProgressPreview)
      }
      LilSettingRow(title: "Подписи поверх изображения", note: "В сохранённый файл они не попадают") {
        Segmented(
          options: HUDMode.allCases.map { ($0, $0.label) },
          value: Binding(get: { s.hudMode }, set: { s.setHUDMode($0) }))
          .fixedSize()
      }
      LilSettingRow(title: "Готовые изображения") {
        SmallButton(title: "Показать в Finder") { s.openOutputFolder() }
      }
      LilSettingRow(
        title: "Папка моделей",
        note: s.folderMove != nil
          ? s.folderMoveNote
          : ModelsFolder.url.path
            + (ModelsFolder.isReachable(ModelsFolder.url) ? "" : " — диск не подключён")
      ) {
        if let fraction = s.folderMove {
          ProgressView(value: fraction).tint(P.accent).frame(width: 160)
        } else {
          HStack(spacing: 8) {
            SmallButton(title: "Показать") { NSWorkspace.shared.open(ModelsFolder.url) }
            SmallButton(title: "Сменить…") { chooseModelsFolder() }
          }
        }
      }
    }
  }

  /// A new place for all the models; the person says whether the ones here go along.
  private func chooseModelsFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.message = "новая папка для всех моделей — на Mac или на внешнем диске"
    panel.prompt = "Выбрать"
    guard panel.runModal() == .OK, let url = panel.urls.first else { return }
    let alert = NSAlert()
    alert.messageText = "Перенести модели в новую папку?"
    alert.informativeText =
      "«Перенести» скопирует все модели туда и уберёт их отсюда — для сотен гигабайт это долго, движок на это время остановится. «Только сменить» — если модели уже лежат в новой папке. lil art перезапустится."
    alert.addButton(withTitle: "Перенести")
    alert.addButton(withTitle: "Только сменить")
    alert.addButton(withTitle: "Отмена")
    switch alert.runModal() {
    case .alertFirstButtonReturn: s.changeModelsFolder(to: url, carry: true)
    case .alertSecondButtonReturn: s.changeModelsFolder(to: url, carry: false)
    default: break
    }
  }
}

@available(macOS 26, *)
private struct PromptSettings: View {
  @ObservedObject var assist: PromptAssist

  var body: some View {
    LilSettingsPage {
      LilSettingRow(title: "Проверка орфографии") {
        LilSwitch(isOn: $assist.spellcheck)
      }
      LilSettingRow(title: "Подсказки из истории", note: "Запомнено фраз: \(assist.historyCount)") {
        HStack(spacing: 10) {
          SmallButton(title: "Очистить", quiet: true) { assist.clearHistory() }
          LilSwitch(isOn: $assist.useHistory)
        }
      }
      ForEach(PromptAssist.Source.allCases, id: \.self) { source in
        LilSettingRow(
          title: "Теги \(source.title)",
          note: assist.isOn(source) ? (assist.status[source] ?? source.size) : source.size
        ) {
          LilSwitch(isOn: Binding(get: { assist.isOn(source) }, set: { assist.set(source, $0) }))
        }
      }
      Text("Список подсказок открывается сам. Слово вставляется, только когда вы его выбрали: стрелки и Enter, Tab или клик. Esc закрывает. Незнакомое слово можно запомнить правым кликом. Словари тегов — a1111-sd-webui-tagcomplete, лицензия MIT.")
        .font(.sans(11)).foregroundStyle(P.muted)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 12)
    }
  }
}

@available(macOS 26, *)
private struct TranslationSettings: View {
  @ObservedObject var translator: Translator

  var body: some View {
    LilSettingsPage {
      LilSettingRow(
        title: "Переводит Prompt",
        note: {
          switch translator.engine {
          case .google:
            return "Бесплатно и без ключа. Текст Prompt уходит в Google Translate. Если Google не ответит, переведёт Apple"
          case .system:
            return "Перевод прямо на этом Mac, в интернет ничего не уходит"
          case .local:
            return "Ваша модель в ollama или lm studio: переводит всё как есть, без цензуры. Если не ответит, переведёт Apple"
          }
        }()
      ) {
        Segmented(
          options: Translator.Engine.allCases.map { ($0, $0.label) }, value: $translator.engine)
          .fixedSize()
      }
      LilSettingRow(
        title: "Улучшает Prompt",
        note: "Всегда на этом Mac: добавляет к Prompt детали света, материалов, объектива"
      ) {
        Segmented(
          options: Translator.Improver.allCases.map { ($0, $0.label) }, value: $translator.improver)
          .fixedSize()
      }

      LilSettingRow(
        title: "Слова, которые нельзя терять",
        note: "Google и Apple молча выбрасывают «неприличные» слова. Если в переводе нет нужного, "
          + "оно дописывается в конец. Строка: начало русского слова = английское"
      ) {
        TextEditor(text: $translator.glossary)
          .textEditorStyle(.plain).font(.mono(10)).scrollContentBackground(.hidden)
          .padding(6).frame(width: 230, height: 120)
          .background(P.panel).overlay(Rectangle().stroke(P.line, lineWidth: 1))
      }

      switch translator.improver == .local || translator.engine == .local ? .local : translator.improver {
      case .apple:
        LilSettingRow(
          title: "Apple Intelligence",
          note: translator.modelAvailable
            ? "Системная модель избегает части тем. Если это мешает — выберите свою модель"
            : translator.modelHint
        ) {
          Text(translator.modelAvailable ? "доступна" : "недоступна").font(.mono(11))
            .foregroundStyle(P.muted)
        }
      case .local:
        LilSettingRow(title: "Программа") {
          Segmented(
            options: Translator.Runtime.allCases.map { ($0, $0.label) }, value: $translator.runtime)
            .fixedSize()
        }
        LilSettingRow(title: "Адрес", note: translator.runtime.install) {
          if translator.runtime == .manual {
            TextField("http://127.0.0.1:8000/v1", text: $translator.endpoint)
              .textFieldStyle(.plain).font(.mono(10))
              .padding(.horizontal, 9).padding(.vertical, 7).frame(width: 230)
              .background(P.panel).overlay(Rectangle().stroke(P.line, lineWidth: 1))
          } else {
            Text(translator.endpoint).font(.mono(10)).foregroundStyle(P.muted)
          }
        }
        LilSettingRow(title: "Модель", note: translator.endpointStatus.isEmpty ? nil : translator.endpointStatus) {
          HStack(spacing: 8) {
            if translator.models.isEmpty {
              Text("сначала найдите сервер").font(.mono(10)).foregroundStyle(P.muted)
            } else {
              Menu {
                ForEach(translator.models, id: \.self) { m in
                  Button(m) { translator.customModel = m }
                }
              } label: {
                DropLabel(title: translator.customModel.isEmpty ? "выберите" : translator.customModel)
              }
              .menuStyle(.button).buttonStyle(.plain).frame(width: 200)
            }
            SmallButton(title: "Найти сервер") { Task { await translator.detectRuntime() } }
          }
        }
      }
    }
  }
}

@available(macOS 26, *)
private struct EngineSettings: View {
  @ObservedObject var s: Studio
  @ObservedObject var engine: EngineHost

  var body: some View {
    LilSettingsPage {
      LilSettingRow(title: "Версия", note: engine.status.isEmpty ? nil : engine.status) {
        HStack(spacing: 10) {
          Text(engine.installedTag.isEmpty ? "не установлен" : engine.installedTag)
            .font(.mono(11)).foregroundStyle(P.muted)
          if !engine.latestTag.isEmpty, engine.latestTag != engine.installedTag {
            // Studio does the whole sequence (release, stop, install, start) and refuses to run
            // under a generation; the button only has to stay out of the way while that happens.
            SmallButton(title: "Обновить до \(engine.latestTag)", strong: true) {
              Task { await s.updateEngine() }
            }
            .disabled(engine.busy || s.busy)
            .opacity(engine.busy || s.busy ? 0.4 : 1)
          } else {
            SmallButton(title: engine.busy ? "Проверяю" : "Проверить обновление") {
              Task { await engine.checkLatest() }
            }
          }
        }
      }
      if engine.busy, engine.progress > 0 {
        ProgressView(value: engine.progress).tint(P.accent).padding(.vertical, 6)
      }
      LilSettingRow(title: "Состояние") {
        HStack(spacing: 10) {
          LED(color: engine.ready ? P.led : (engine.running ? P.amber : P.muted))
          Text(engine.ready ? "работает" : (engine.running ? "запускается" : "остановлен"))
            .font(.mono(11)).foregroundStyle(P.muted)
          SmallButton(title: engine.running ? "Перезапустить" : "Запустить") {
            s.restartEngine()
          }
        }
      }
      CacheRow(s: s)
      Text("Движок работает на этом Mac и слушает только этот компьютер: в локальной сети его не видно. Prompt и изображения никуда не отправляются")
        .font(.sans(11)).foregroundStyle(P.muted).padding(.top, 12)
    }
  }
}

/// How much of the model the engine keeps in memory between pictures.
@available(macOS 26, *)
private struct CacheRow: View {
  @ObservedObject var s: Studio

  private var _typed = SwiftUI.State(initialValue: "")
  private var typed: String {
    get { _typed.wrappedValue }
    nonmutating set { _typed.wrappedValue = newValue }
  }

  private var presets: [Double] { [0, 8, s.maxCacheGB] }

  private var note: String {
    let model = Double(s.modelBytes) / 1_073_741_824
    var text = "Модель остаётся в памяти между генерациями, если помещается в этот объём. Движок перезапустится"
    if model > 0 {
      text += String(format: ". Выбранная модель весит %.1f ГБ", model)
      if s.cacheGB < model {
        text += " — это больше выбранного объёма, поэтому она загружается заново каждый раз"
      }
    }
    return text
  }

  var body: some View {
    LilSettingRow(title: "Держать модель в памяти", note: note) {
      HStack(spacing: 8) {
        Segmented(
          options: [(0.0, "Нет"), (8.0, "8 ГБ"), (s.maxCacheGB, "Максимум")],
          value: Binding(get: { s.cacheGB }, set: { s.applyCache($0) }))
          .fixedSize()
        HStack(spacing: 4) {
          TextField(
            "своё",
            text: Binding(
              get: {
                typed.isEmpty && !presets.contains(s.cacheGB) ? String(Int(s.cacheGB)) : typed
              },
              set: { typed = $0.filter(\.isNumber) })
          )
          .textFieldStyle(.plain).font(.mono(11)).frame(width: 34)
          .onSubmit {
            if let value = Double(typed) { s.applyCache(min(value, Mem.machineGB)) }
            typed = ""
          }
          Text("ГБ").font(.mono(9)).foregroundStyle(P.muted)
        }
        .padding(.horizontal, 8).frame(height: 30)
        .background(P.panel).overlay(Rectangle().stroke(P.line, lineWidth: 1))
        .help("Своё число гигабайт, Enter — применить")
      }
    }
  }
}
