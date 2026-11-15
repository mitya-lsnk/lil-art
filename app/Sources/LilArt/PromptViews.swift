import AVKit
import MediaGenerationKit
import SwiftUI
import Translation
import UniformTypeIdentifiers

@available(macOS 26, *)
struct PromptBox: View {
  @ObservedObject var s: Studio

  private var hasEnglish: Bool { !s.englishPrompt.isEmpty }

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack {
        Cap(text: "Prompt")
        // What a run will send, so the person never has to guess. It sits up here, where it
        // may shrink: in the row of buttons below, a line that did not fit pushed the whole
        // sidebar wider than the window.
        Group {
          if s.translating {
            Text("перевожу")
          } else if s.englishCurrent {
            Text("уйдёт: перевод").foregroundStyle(P.ink)
          } else if s.englishStale {
            Text("текст изменён — уйдёт как написано")
          } else if s.showingEnglish, !hasEnglish {
            Text("английский пуст — уйдёт русский")
          }
        }
        .font(.mono(9)).tracking(0.6).foregroundStyle(P.muted)
        .lineLimit(1).truncationMode(.tail).minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity, alignment: .trailing)
        if hasEnglish || s.showingEnglish {
          Segmented(
            options: [(false, "ру"), (true, "en")],
            value: Binding(get: { s.showingEnglish }, set: { s.showingEnglish = $0 }))
            .fixedSize()
        }
      }
      .frame(height: 30)

      VStack(spacing: 0) {
        if s.showingEnglish {
          // what the model will read; editable, so a clumsy translation can be put right
          PromptTextView(
            text: Binding(get: { s.englishPrompt }, set: { s.editEnglish($0) }), fontSize: 12,
            assist: s.assist
          )
          .id("english")
          .padding(4)
          .frame(height: 104)
        } else {
          PromptTextView(text: $s.prompt, assist: s.assist)
            .padding(4)
            .frame(height: 104)
        }

        HStack(spacing: 6) {
          MagicButton(s: s).fixedSize()
          Spacer(minLength: 4)
          PresetButton(s: s)
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(P.panel2)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(P.hair), alignment: .top)
      }
      .background(P.panel)
      .overlay(RoundedRectangle(cornerRadius: 9).stroke(P.line, lineWidth: 1))
      .clipShape(RoundedRectangle(cornerRadius: 9))

      if s.proOnThisTab, s.translator.engine == .local || s.translator.improver == .local {
        LocalModelRow(translator: s.translator)
      }
    }
  }
}
/// PRO, under the prompt: which language model of the local server translates and improves, and
/// whether the server answers at all.
@available(macOS 26, *)
struct LocalModelRow: View {
  @ObservedObject var translator: Translator

  /// The model list drawn at the height of the buttons around it (26), not the 34 of the
  /// big menus.
  private func field(_ title: String, chevron: Bool = true) -> some View {
    HStack(spacing: 0) {
      Text(title)
        .font(.mono(10)).tracking(0.5).foregroundStyle(P.ink)
        .lineLimit(1).truncationMode(.middle)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
      if chevron {
        Rectangle().fill(P.line).frame(width: 1)
        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
          .foregroundStyle(P.ink).frame(width: 24).background(P.panel2)
      }
    }
    .frame(height: 26)
    .background(P.panel)
    .overlay(Rectangle().stroke(P.line, lineWidth: 1))
    .contentShape(Rectangle())
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Text("МОДЕЛЬ").font(.mono(9)).tracking(0.8).foregroundStyle(P.muted).fixedSize()
        if translator.models.isEmpty {
          field("список пуст", chevron: false).foregroundStyle(P.muted)
        } else {
          Menu {
            ForEach(translator.models, id: \.self) { model in
              Button((translator.customModel == model ? "✓ " : "") + model) { translator.customModel = model }
            }
          } label: {
            field(translator.customModel.isEmpty ? "выберите" : translator.customModel)
          }
          .menuStyle(.button).buttonStyle(.plain)
          .frame(maxWidth: 150)
          .help(translator.customModel.isEmpty ? "Модель сервера" : translator.customModel)
        }
        Spacer(minLength: 0)
        SmallButton(title: translator.checking ? "Проверяю" : "Проверить") {
          Task { await translator.refreshModels() }
        }
        .disabled(translator.checking)
        .help("Проверить, отвечает ли сервер, и обновить список моделей")
      }
      if !translator.endpointStatus.isEmpty {
        Text(translator.endpointStatus)
          .font(.mono(9)).tracking(0.3).foregroundStyle(P.muted)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    // 8 in from the box on both sides: the row ends where the buttons above it end
    .padding(.horizontal, 8)
    .onAppear { if translator.models.isEmpty { Task { await translator.refreshModels() } } }
  }
}
/// Two buttons that act once, when pressed: «Перевести» makes the English of what is in the
/// box now, «Улучшить» makes it and adds detail. Neither stays switched on, so nothing is
/// translated unless asked for.
@available(macOS 26, *)
struct MagicButton: View {
  @ObservedObject var s: Studio

  var body: some View {
    HStack(spacing: 6) {
      action("ПЕРЕВЕСТИ", icon: "character.bubble", help: "Перевести Prompt на английский сейчас") {
        s.translate()
      }
      action("УЛУЧШИТЬ", icon: "wand.and.stars", help: "Перевести и добавить детали света, материалов, объектива") {
        s.translate(improve: true)
      }
      if !s.englishPrompt.isEmpty {
        Button { s.revertTranslation() } label: {
          Image(systemName: "arrow.uturn.backward").font(.system(size: 10, weight: .bold))
            .foregroundStyle(P.ink)
            .frame(width: 30, height: 26)
            .background(P.panel)
            .overlay(Rectangle().stroke(P.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Обратить перевод: вернуть Prompt как был написан, без английского")
      }
    }
    .disabled(s.translating)
    .opacity(s.translating ? 0.5 : 1)
  }

  private func action(_ title: String, icon: String, help: String, _ run: @escaping () -> Void)
    -> some View
  {
    Button(action: run) {
      HStack(spacing: 5) {
        Image(systemName: icon).font(.system(size: 10))
        Text(title).font(.mono(9, .bold)).tracking(1).lineLimit(1)
      }
      .foregroundStyle(P.ink)
      .padding(.horizontal, 8).frame(height: 26)
      .background(P.panel)
      .overlay(Rectangle().stroke(P.line, lineWidth: 1))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(help)
  }
}
@available(macOS 26, *)
/// Presets add words of style to the prompt, so they sit in the prompt box's corner.
struct PresetButton: View {
  @ObservedObject var s: Studio

  private var chosen: Preset? { s.presets.first { $0.id == s.chosenPreset } }

  var body: some View {
    Menu {
      Button("Без пресета") { s.chosenPreset = nil }
      Divider()
      ForEach(s.presets) { preset in
        Button(preset.name) { s.chosenPreset = preset.id }
      }
    } label: {
      HStack(spacing: 5) {
        Image(systemName: "square.stack.3d.up").font(.system(size: 10))
        Text((chosen?.name ?? "пресет").uppercased()).font(.mono(9, .bold)).tracking(1)
          .lineLimit(1).truncationMode(.tail).frame(maxWidth: 110)
        Image(systemName: "chevron.down").font(.system(size: 7))
      }
      .foregroundStyle(chosen == nil ? P.muted : P.accentInk)
      .padding(.horizontal, 8).frame(height: 26)
      .background(chosen == nil ? P.panel : P.accent)
      .overlay(Rectangle().stroke(chosen == nil ? P.line : P.accent, lineWidth: 1))
    }
    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
    .fixedSize()
    .help("Пресет дописывает к Prompt слова стиля")
  }
}
@available(macOS 26, *)
struct NumberField: View {
  @Binding var value: Int

  /// What is being typed. Writing every keystroke straight into the number made the field
  /// impossible to clear: it snapped back on each Backspace. The typed text is shown only
  /// while it still means the current value, so a value changed elsewhere always shows.
  private var _draft = SwiftUI.State<String?>(initialValue: nil)
  private var draft: String? {
    get { _draft.wrappedValue }
    nonmutating set { _draft.wrappedValue = newValue }
  }

  init(value: Binding<Int>) { self._value = value }

  var body: some View {
    TextField(
      "",
      text: Binding(
        get: {
          if let draft, draft.isEmpty || Int(draft) == value { return draft }
          return String(value)
        },
        set: { text in
          let digits = text.filter(\.isNumber)
          draft = digits
          if let number = Int(digits.prefix(9)) { value = number }
        })
    )
    .onSubmit { draft = nil }
    .textFieldStyle(.plain)
    .font(.mono(11))
    .padding(.horizontal, 10).padding(.vertical, 8)
    .background(P.panel2)
    .overlay(Rectangle().stroke(P.line, lineWidth: 1))
  }
}
@available(macOS 26, *)
struct DecimalField: View {
  @Binding var value: Double
  /// Typed numbers outside this are pulled back in; "inf" and "nan" never get through.
  var range: ClosedRange<Double> = 0...100

  /// Same idea as NumberField: "3." stays "3." while the user is still typing "3.5".
  private var _draft = SwiftUI.State<String?>(initialValue: nil)
  private var draft: String? {
    get { _draft.wrappedValue }
    nonmutating set { _draft.wrappedValue = newValue }
  }

  init(value: Binding<Double>, range: ClosedRange<Double> = 0...100) {
    self._value = value
    self.range = range
  }

  private static func parse(_ text: String) -> Double? {
    let clean = text.replacingOccurrences(of: ",", with: ".")
    guard clean.allSatisfy({ $0.isNumber || $0 == "." }), let number = Double(clean),
      number.isFinite
    else { return nil }
    return number
  }

  var body: some View {
    TextField(
      "",
      text: Binding(
        get: {
          if let draft, draft.isEmpty || Self.parse(draft) == value { return draft }
          return String(format: "%.1f", value)
        },
        set: { text in
          draft = text
          if let number = Self.parse(text) {
            value = min(max(number, range.lowerBound), range.upperBound)
          }
        })
    )
    .onSubmit { draft = nil }
    .textFieldStyle(.plain)
    .font(.mono(11))
    .padding(.horizontal, 10).padding(.vertical, 8)
    .background(P.panel2)
    .overlay(Rectangle().stroke(P.line, lineWidth: 1))
  }
}
@available(macOS 26, *)
struct SpecRow: View {
  let k: String
  let v: String

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(k.uppercased()).font(.mono(9)).tracking(0.8).foregroundStyle(P.muted)
      Rectangle().fill(P.hair).frame(height: 1).offset(y: -3)
      Text(v).font(.mono(11, .semibold)).foregroundStyle(P.ink)
    }
  }
}
