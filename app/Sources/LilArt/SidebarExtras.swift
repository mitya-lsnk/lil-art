import AVKit
import MediaGenerationKit
import SwiftUI
import Translation
import UniformTypeIdentifiers

/// Pictures handed to the model along with the words.
@available(macOS 26, *)
struct ReferenceRow: View {
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
struct SizePresetRow: View {
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
struct SizeField: View {
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
struct BatchGrid: View {
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
/// The upscaler switch and, when on, its settings. The same in the simple and the pro view.
@available(macOS 26, *)
struct UpscaleSection: View {
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
struct UpscaleBlock: View {
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
struct LoRABlock: View {
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
struct LoRARow: View {
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
struct SaveForModelRow: View {
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
