import AVKit
import MediaGenerationKit
import SwiftUI
import Translation
import UniformTypeIdentifiers

@available(macOS 26, *)
struct Sidebar: View {
  @ObservedObject var s: Studio

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        if s.tab == .video {
          VideoSidebar(s: s).padding(18)
        } else {
          VStack(alignment: .leading, spacing: 15) {
            ModelRow(s: s)
            if s.tab == .edit {
              EditBox(s: s)
              MaskTools(s: s)
              if !s.canEdit { EditStrengthRow(s: s) }
            }
            PromptBox(s: s)
            if s.tab == .edit { PhrasesRow(s: s) }
            if s.regionsAvailable, s.tab == .image { RegionsBlock(s: s) }

            if s.pro {
              HStack {
                Cap(text: "Negative prompt")
                Spacer()
                LilSwitch(isOn: $s.negativeOn).scaleEffect(0.75)
              }
              if s.negativeOn { NegativeBox(s: s) }

              ProSizeBlock(s: s)
              UpscaleSection(s: s)

              HStack {
                Cap(text: "LoRA")
                Spacer()
                LilSwitch(isOn: $s.loraOn).scaleEffect(0.75)
              }
              if s.loraOn { LoRABlock(s: s) }
            }

            // the edit tab has its own pictures above; these are the picture tab's inputs
            if s.tab == .image { ReferenceRow(s: s) }
            if s.tab == .edit, !s.controlItems.isEmpty { ControlNetBlock(s: s) }

            if s.pro {
              ProBlock(s: s)
            } else {
              VStack(alignment: .leading, spacing: 8) {
                Cap(text: "качество")
                Segmented(
                  options: Quality.allCases.map { ($0, $0.label) }, value: $s.quality, fill: true)
                Text(
                  s.recommended == nil
                    ? "как советует сама модель"
                    : "Steps \(s.effectiveSteps ?? 0) · от того, что советует модель"
                )
                .font(.mono(9)).tracking(0.3).foregroundStyle(P.muted)
              }
              SizeRow(s: s)
              UpscaleSection(s: s)
            }

            BatchRow(s: s)
          }
          .padding(18)
        }
      }

      GenerateBar(s: s)
        .padding(.horizontal, 18).padding(.vertical, 16)
        .background(P.panel2)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(P.line), alignment: .top)
    }
    .frame(width: 392)
    .background(P.bg)
  }
}
/// Model on the left, the pro switch right beside it.
@available(macOS 26, *)
struct ModelRow: View {
  @ObservedObject var s: Studio
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Cap(text: "модель")
      HStack(spacing: 8) {
        Menu {
          Section("Готовы") {
            ForEach(s.models) { m in
              Button {
                s.selectModel(m.file)
              } label: {
                Text(m.file == s.model ? "✓  " + m.name : m.name)
                Text([m.familyLabel, m.sizeLabel].filter { !$0.isEmpty }.joined(separator: " · "))
              }
            }
            if s.models.isEmpty { Text("моделей пока нет") }
          }
          if !s.library.preparing.isEmpty {
            Section("Готовится") {
              ForEach(s.library.preparing) { job in
                Text(
                  job.name + " · " + job.stage.label.lowercased()
                    + (job.stage.isRunning && job.progress > 0 ? " \(Int(job.progress * 100))%" : ""))
              }
            }
          }
          Divider()
          Button("Модели…") { openWindow(id: "models") }
        } label: {
          DropLabel(
            title: s.models.first(where: { $0.file == s.model })?.name
              ?? s.model.replacingOccurrences(of: ".ckpt", with: ""),
            strong: true)
        }
        .menuStyle(.button).buttonStyle(.plain)
        .fixedSize(horizontal: false, vertical: true)

        FinderButton(s: s)

        ProToggle(isOn: $s.pro)
      }
    }
    .sheet(isPresented: $s.showSettingsFinder) { SettingsFinder(s: s) }
  }
}
/// The PRO checkbox that sits next to the model picker on both tabs.
@available(macOS 26, *)
struct ProToggle: View {
  @Binding var isOn: Bool

  var body: some View {
    Button { isOn.toggle() } label: {
      HStack(spacing: 6) {
        Image(systemName: isOn ? "checkmark.square.fill" : "square")
          .font(.system(size: 11))
        Text("PRO").font(.mono(10, .bold)).tracking(1.2)
      }
      .foregroundStyle(isOn ? P.accentInk : P.ink)
      .padding(.horizontal, 12).frame(height: 34)
      .background(isOn ? P.accent : P.panel)
      .overlay(Rectangle().stroke(isOn ? P.accent : P.line, lineWidth: 1))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}
/// Aspect and size, two small dropdowns on one line.
@available(macOS 26, *)
struct SizeRow: View {
  @ObservedObject var s: Studio

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Cap(text: "размер")
        if s.pictureToFit != nil { FitSizeButton(s: s) }
      }
      HStack(spacing: 8) {
        SmallMenu(title: s.aspect.label) {
          ForEach(Aspect.menu, id: \.self) { a in
            Button(a.label) { s.aspect = a }
            if a != .square {
              Button(a.flipped.label) { s.aspect = a.flipped }
            }
          }
        }
        Button { s.flipAspect() } label: {
          Image(systemName: "arrow.triangle.2.circlepath")
            .font(.system(size: 11))
            .foregroundStyle(s.aspect == .square ? P.muted : P.ink)
            .frame(width: 34, height: 34)
            .background(P.panel)
            .overlay(Rectangle().stroke(P.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(s.aspect == .square)
        .help("повернуть пропорции")

        SmallMenu(title: s.megapixels.label) {
          ForEach(Megapixels.allCases, id: \.self) { m in
            Button(m.label) { s.megapixels = m }
          }
        }
      }
      Text("получится \(s.sizeLabel)")
        .font(.mono(9)).tracking(0.3).foregroundStyle(P.ink.opacity(0.35))
    }
  }
}
@available(macOS 26, *)
struct SmallMenu<Content: View>: View {
  let title: String
  @ViewBuilder var content: Content

  var body: some View {
    Menu {
      content
    } label: {
      DropLabel(title: title, strong: true)
    }
    .menuStyle(.button).buttonStyle(.plain)
    .fixedSize(horizontal: false, vertical: true)
  }
}
@available(macOS 26, *)
struct BatchRow: View {
  @ObservedObject var s: Studio

  var body: some View {
    HStack {
      Cap(text: "изображений за генерацию")
      Spacer()
      NumberField(value: Binding(get: { s.batch }, set: { s.batch = max(1, min(16, $0)) }))
        .frame(width: 70)
    }
  }
}
/// Everything the pro checkbox reveals.
/// VAE, text encoder and other parts of the model, every one the model has, each with the
/// added copies that fit it and a way to add another.
@available(macOS 26, *)
struct PartsBlock: View {
  @ObservedObject var s: Studio
  let entry: InstalledModel?
  var strong = false

  var body: some View {
    ForEach(s.partSlots(for: entry)) { item in
      VStack(alignment: .leading, spacing: 7) {
        Cap(text: item.slot.title)
        Menu {
          let chosen = s.chosenPart(item.slot, for: entry)?.file
          Button(chosen == nil ? "✓  Стандартный" : "Стандартный") {
            s.choosePart(nil, item.slot, for: entry)
          }
          ForEach(item.options) { option in
            Button(option.file == chosen ? "✓  " + option.name : option.name) {
              s.choosePart(option.file, item.slot, for: entry)
            }
          }
          Divider()
          Button("Добавить свой…") { s.addPartFile() }
          Text("сейчас стандартный: \(item.stock)")
        } label: {
          DropLabel(title: s.chosenPart(item.slot, for: entry)?.name ?? "Стандартный", strong: strong)
        }
        .menuStyle(.button).buttonStyle(.plain)
        .fixedSize(horizontal: false, vertical: true)
        Text(hint(item.slot))
          .font(.mono(9)).tracking(0.3).foregroundStyle(P.muted)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func hint(_ slot: ModelParts.Slot) -> String {
    switch slot {
    case .autoencoder: return "превращает результат в картинку: резкость, цвет, мелкие детали"
    case .textEncoder, .t5Encoder, .clipEncoder:
      return "читает промпт; дообученный лучше понимает темы, на которых его учили"
    case .imageEncoder: return "читает картинку на входе"
    }
  }
}
@available(macOS 26, *)
struct ProBlock: View {
  @ObservedObject var s: Studio

  var body: some View {
    VStack(alignment: .leading, spacing: 15) {
      VStack(alignment: .leading, spacing: 8) {
        Cap(text: "Sampler")
        Menu {
          ForEach(Samplers.all, id: \.0) { item in
            Button(item.1) { s.sampler = item.0 }
          }
        } label: {
          DropLabel(title: Samplers.name(s.sampler))
        }
        .menuStyle(.button).buttonStyle(.plain)
        .fixedSize(horizontal: false, vertical: true)
        Text(Samplers.hint(for: s.sampler))
          .font(.mono(9)).tracking(0.3).foregroundStyle(P.muted)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 7) {
          HStack(spacing: 6) {
            Cap(text: "Steps", rule: false)
            InfoDot(text: Guidance.steps)
          }
          NumberField(value: Binding(get: { s.proSteps }, set: { s.proSteps = max(1, min(60, $0)) }))
        }
        VStack(alignment: .leading, spacing: 7) {
          HStack(spacing: 6) {
            Cap(text: "CFG", rule: false)
            InfoDot(text: Guidance.cfg)
          }
          DecimalField(
            value: Binding(get: { Double(s.proCFG) }, set: { s.proCFG = Float($0) }))
        }
        // shift matters as much as steps for the flow models (FLUX.3 klein wants 16), so it
        // sits beside them rather than under the fold
        if let entry = s.modelEntry,
          let traits = s.traits(for: entry, masked: s.tab == .edit && !s.maskIsEmpty),
          let shift = Tweaks.all.first(where: { $0.id == "shift" }), shift.applies(traits)
        {
          VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
              Cap(text: "Shift", rule: false)
              InfoDot(text: shift.hint)
            }
            DecimalField(
              value: Binding(
                get: { s.tweakValue(shift, for: entry) },
                set: { s.setTweak(shift, max(0.1, min(20, $0)), for: entry) }),
              range: 0.1...20)
          }
        }
      }

      SaveForModelRow(s: s)

      PartsBlock(s: s, entry: s.modelEntry)
      TweaksBlock(s: s, entry: s.modelEntry, masked: s.tab == .edit && !s.maskIsEmpty)

      SeedRow(s: s)
    }
  }
}
/// Seed with its dice and its lock. Both tabs need it, so it lives on its own.
@available(macOS 26, *)
struct SeedRow: View {
  @ObservedObject var s: Studio

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 6) {
        Cap(text: "Seed", rule: false)
        InfoDot(
          text: """
            SEED

            Это число, с которого начинается шум.
            Один и тот же Seed при тех же настройках даёт то же изображение.

            Впишите своё число или нажмите кубик — Seed зафиксируется.
            Замок держит число, чтобы менять Prompt и смотреть,
            что изменилось именно от слов. Пустое поле — случайный.
            """)
      }
      HStack(spacing: 8) {
        // Typing a number fixes the seed right away; clearing the field makes it random again.
        TextField(
          "случайный",
          text: Binding(
            get: { s.seedLocked ? String(s.lockedSeed) : "" },
            set: { text in
              let digits = text.filter(\.isNumber)
              if digits.isEmpty {
                s.seedLocked = false
              } else if let value = UInt32(digits.prefix(10)) {
                s.lockedSeed = value
                s.seedLocked = true
              }
            })
        )
        .textFieldStyle(.plain)
        .font(.mono(11)).foregroundStyle(P.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(P.panel2).overlay(Rectangle().stroke(P.line, lineWidth: 1))
        .help("Введите число, чтобы зафиксировать Seed. Пустое поле — случайный")
        Button {
          s.lockedSeed = UInt32.random(in: 0...UInt32(Int32.max))
          s.seedLocked = true
        } label: {
          Image(systemName: "die.face.5").font(.system(size: 12)).foregroundStyle(P.ink)
            .frame(width: 32, height: 32)
            .background(P.panel).overlay(Rectangle().stroke(P.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        Button { s.seedLocked.toggle() } label: {
          Image(systemName: s.seedLocked ? "lock.fill" : "lock.open")
            .font(.system(size: 12))
            .foregroundStyle(s.seedLocked ? P.accentInk : P.ink)
            .frame(width: 32, height: 32)
            .background(s.seedLocked ? P.accent : P.panel)
            .overlay(Rectangle().stroke(s.seedLocked ? P.accent : P.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
      }
    }
  }
}
/// Width and height in pro mode, right under the negative prompt.
@available(macOS 26, *)
struct ProSizeBlock: View {
  @ObservedObject var s: Studio

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack {
        Cap(text: "размер")
        Spacer()
        if s.pictureToFit != nil {
          FitSizeButton(s: s)
        }
        Segmented(
          options: [(false, "цифры"), (true, "поле")],
          value: Binding(get: { s.showSizePad }, set: { s.showSizePad = $0 }))
      }
      if s.showSizePad {
        HStack(alignment: .top, spacing: 12) {
          SizePad(
            width: Binding(
              get: { s.proWidth }, set: { s.proWidth = $0; s.widthText = String($0) }),
            height: Binding(
              get: { s.proHeight }, set: { s.proHeight = $0; s.heightText = String($0) }),
            lockWidth: s.lockWidth, lockHeight: s.lockHeight
          )
          .frame(width: 186, height: 186)

          VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
              SizeField(label: "Ш", text: $s.widthText, commit: s.commitSize).frame(width: 78)
              SideLock(on: $s.lockWidth, help: "ширина не меняется, пока тянешь поле")
              Button { s.swapSize() } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                  .font(.system(size: 10))
                  .foregroundStyle(P.ink)
                  .frame(width: 28, height: 28)
                  .background(P.panel)
                  .overlay(Rectangle().stroke(P.line, lineWidth: 1))
              }
              .buttonStyle(.plain)
              .help("поменять ширину и высоту местами")
            }
            HStack(spacing: 6) {
              SizeField(label: "В", text: $s.heightText, commit: s.commitSize).frame(width: 78)
              SideLock(on: $s.lockHeight, help: "высота не меняется, пока тянешь поле")
              Text(String(format: "%.1f мп", Double(s.proWidth * s.proHeight) / 1_000_000))
                .font(.mono(9)).foregroundStyle(P.muted)
            }

            Rectangle().fill(P.hair).frame(height: 1).padding(.vertical, 1)

            ForEach(Array(SizePreset.allCases.enumerated()), id: \.offset) { _, preset in
              let on = (s.proWidth, s.proHeight) == preset.size
              Button {
                s.proWidth = preset.size.0
                s.proHeight = preset.size.1
                s.widthText = String(preset.size.0)
                s.heightText = String(preset.size.1)
              } label: {
                Text(preset.label)
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
          Spacer(minLength: 0)
        }
      } else {
        HStack(spacing: 8) {
          SizeField(label: "Ш", text: $s.widthText, commit: s.commitSize)
          Button { s.swapSize() } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
              .font(.system(size: 11))
              .foregroundStyle(P.ink)
              .frame(width: 34, height: 30)
              .background(P.panel)
              .overlay(Rectangle().stroke(P.line, lineWidth: 1))
          }
          .buttonStyle(.plain)
          SizeField(label: "В", text: $s.heightText, commit: s.commitSize)
        }
        SizePresetRow(s: s)
      }
      Text("движок принимает только кратное 64 · округлю сам при запуске")
        .font(.mono(9)).tracking(0.3).foregroundStyle(P.muted)
    }
  }
}
@available(macOS 26, *)
struct NegativeBox: View {
  @ObservedObject var s: Studio

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      VStack(spacing: 0) {
        PromptTextView(text: $s.negative, fontSize: 12, assist: s.assist, useHistory: false)
          .padding(4)
          .frame(height: 54)
        HStack(spacing: 8) {
          Button { s.translateNegative() } label: {
            HStack(spacing: 5) {
              Image(systemName: "wand.and.stars").font(.system(size: 10))
              Text("НА АНГЛИЙСКИЙ").font(.mono(9, .bold)).tracking(1)
            }
            .foregroundStyle(P.ink)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(P.panel2)
            .overlay(Rectangle().stroke(P.line, lineWidth: 1))
          }
          .buttonStyle(.plain)
          Spacer()
          if s.translatingNegative {
            Text("перевожу").font(.mono(9)).tracking(0.6).foregroundStyle(P.muted)
          }
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(P.panel2)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(P.hair), alignment: .top)
      }
      .background(P.panel)
      .overlay(RoundedRectangle(cornerRadius: 9).stroke(P.line, lineWidth: 1))
      .clipShape(RoundedRectangle(cornerRadius: 9))
    }
  }
}
/// One wide button; while it works, it gives up its right end to a stop button.
@available(macOS 26, *)
struct GenerateBar: View {
  @ObservedObject var s: Studio

  var body: some View {
    HStack(spacing: 8) {
      HWButton(
        title: s.busy ? "добавить в очередь" : "Сгенерировать", hint: "⌘ ↵", primary: true
      ) { s.enqueue() }
        // HWButton is drawn by hand and cannot carry a shortcut itself; this invisible
        // button gives ⌘↵ to the main window only, even while the prompt is being typed.
        .background {
          Button("") { s.enqueue() }
            .keyboardShortcut(.return, modifiers: .command)
            .opacity(0).frame(width: 0, height: 0)
        }

      if s.busy || s.queued > 0 {
        HWButton(title: "", symbol: "stop.fill", primary: true, fixedWidth: 54) {
          s.cancelAll()
        }
        .help("прервать и очистить очередь")
      }
    }
  }
}
