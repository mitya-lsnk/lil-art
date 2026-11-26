import SwiftUI
import UniformTypeIdentifiers

/// The one place for models: what is installed, what is on its way in, and the catalog.
@available(macOS 26, *)
struct ModelsWindow: View {
  @ObservedObject var s: Studio
  @ObservedObject private var library: ModelLibrary

  init(s: Studio) {
    self.s = s
    self.library = s.library
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Segmented(
          options: [(false, "Установлены · \(library.installed.count)"), (true, "Каталог")],
          value: $library.catalogTab)
        Spacer()
        HWButton(title: "Добавить файл…", fixedWidth: 170) { library.pickFiles() }
      }
      .padding(16)
      .background(P.panel)
      .overlay(Rectangle().frame(height: 1).foregroundStyle(P.line), alignment: .bottom)

      if library.catalogTab {
        CatalogPane(s: s, library: library, c: s.catalog)
      } else {
        InstalledPane(s: s, library: library)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .dropDestination(for: URL.self) { urls, _ in
      library.add(urls)
      library.catalogTab = false
      return !urls.isEmpty
    }
    .lilAppearance()
    .focusEffectDisabled()
  }
}

@available(macOS 26, *)
private struct InstalledPane: View {
  @ObservedObject var s: Studio
  @ObservedObject var library: ModelLibrary
  @State private var showTechnical = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 10) {
        HStack(spacing: 8) {
          Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(P.muted)
          TextField("Найти", text: $library.query).textFieldStyle(.plain).font(.mono(11))
        }
        .padding(.horizontal, 10).frame(height: 32)
        .background(P.panel).overlay(Rectangle().stroke(P.line, lineWidth: 1))

        CatChip(title: "Все", on: library.roleFilter == nil) { library.roleFilter = nil }
        CatChip(title: "Checkpoint", on: library.roleFilter == .checkpoint) {
          library.roleFilter = .checkpoint
        }
        CatChip(title: "LoRA", on: library.roleFilter == .lora) { library.roleFilter = .lora }
        CatChip(title: "Upscaler", on: library.roleFilter == .upscaler) {
          library.roleFilter = .upscaler
        }
        if !library.parts.isEmpty || library.roleFilter == .part {
          CatChip(title: "VAE и кодировщики", on: library.roleFilter == .part) {
            library.roleFilter = .part
          }
        }
      }

      HStack(spacing: 10) {
        Text("Перетащите .safetensors в это окно или положите его в папку моделей")
          .font(.sans(12)).foregroundStyle(P.muted)
        Spacer(minLength: 8)
        Menu {
          Button(library.importPlan == nil ? "✓  как скачано" : "как скачано") { library.importPlan = nil }
          Divider()
          ForEach(CompressionPlan.presets, id: \.name) { preset in
            Button(library.importPlan == preset.plan ? "✓  " + preset.name : preset.name) {
              library.importPlan = preset.plan
            }
          }
        } label: {
          Text("сжимать новые: " + (library.importPlan?.label ?? "как скачано"))
            .font(.mono(9, .bold)).tracking(0.6).foregroundStyle(P.ink)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .overlay(Rectangle().stroke(P.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("как сжимать модели сразу после конвертации: «как скачано» возвращает fp8 к 8 битам, 16-битные оставляет")
        Button { library.reveal(library.modelsDir) } label: {
          Text("Показать папку в Finder").font(.mono(9, .bold)).tracking(0.8).foregroundStyle(P.ink)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .overlay(Rectangle().stroke(P.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
      }
      .padding(.horizontal, 12).padding(.vertical, 9)
      .overlay(Rectangle().stroke(P.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))

      DiskRow(library: library)

      ScrollView {
        LazyVStack(spacing: 6) {
          ForEach(library.jobs) { job in
            JobRow(library: library, job: job)
          }
          let cards = library.visible.filter { $0.role == .checkpoint }
          if !cards.isEmpty {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 10)], spacing: 10) {
              ForEach(cards) { model in ModelCard(s: s, library: library, model: model) }
            }
            .padding(.bottom, 6)
          }
          ForEach(library.visible.filter { $0.role == .lora }) { model in
            InstalledRow(s: s, library: library, model: model)
          }
          let technical = library.visible.filter { $0.role != .checkpoint && $0.role != .lora }
          if !technical.isEmpty {
            // VAE, text encoders and upscalers work behind the scenes: out of sight until asked for
            DisclosureGroup(
              isExpanded: Binding(
                // chosen with the filter chips above, they are shown open
                get: { showTechnical || library.roleFilter == .part || library.roleFilter == .upscaler },
                set: { showTechnical = $0 })
            ) {
              VStack(spacing: 6) {
                ForEach(technical) { model in InstalledRow(s: s, library: library, model: model) }
              }
              .padding(.top, 6)
            } label: {
              Text("Технические: VAE, кодировщики, апскейлеры · \(technical.count)")
                .font(.mono(10, .bold)).tracking(0.6).foregroundStyle(P.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { showTechnical.toggle() } }
            }
            .padding(.horizontal, 4).padding(.top, 8)
          }
          if library.jobs.isEmpty, library.visible.isEmpty {
            Text(library.installed.isEmpty ? "Моделей пока нет. Скачайте из каталога или добавьте файл" : "Ничего не нашлось")
              .font(.sans(13)).foregroundStyle(P.muted)
              .frame(maxWidth: .infinity).padding(.vertical, 40)
          }
        }
      }

      HStack {
        Text(library.modelsDir.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
        Spacer()
        Button("стереть время запусков") {
          RunTimes.clear(in: .standard)
          s.coverStamp += 1
        }
        .buttonStyle(.plain).foregroundStyle(P.muted)
        .help("забыть, сколько длились генерации: время в карточках начнёт считаться заново")
        Text(String(format: "Занято моделями: %.1f ГБ", Double(library.totalBytes) / 1_073_741_824))
      }
      .font(.mono(9)).foregroundStyle(P.muted)
    }
    .padding(16)
  }
}

/// A file on its way in. It stays on screen with its reason when something goes wrong.
@available(macOS 26, *)
private struct JobRow: View {
  @ObservedObject var library: ModelLibrary
  let job: ImportJob

  private var tint: Color {
    if job.failure != nil { return P.accent }
    return job.stage.isRunning ? P.accent : P.line
  }

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text(job.name).font(.sans(13, .bold)).foregroundStyle(P.ink).lineLimit(1)
        Text(job.role.badge)
          .font(.mono(8, .bold)).tracking(0.9).foregroundStyle(P.muted)
      }
      .frame(width: 230, alignment: .leading)

      TimelineView(.periodic(from: .now, by: 1)) { _ in
        VStack(alignment: .leading, spacing: 5) {
          if let reason = job.failure {
            Text("Не получилось. ").font(.mono(10, .bold)).foregroundStyle(P.accentText)
              + Text(reason.prefix(1).uppercased() + reason.dropFirst()).font(.mono(10))
              .foregroundStyle(P.ink)
          } else if job.stage == .done {
            Text("Готова. ").font(.mono(10, .bold)).foregroundStyle(P.ink)
              + Text(job.note ?? "").font(.mono(10)).foregroundStyle(P.muted)
          } else {
            let percent = job.stage.isRunning && job.progress > 0 ? " · \(Int(job.progress * 100))%" : ""
            Text(job.stage.label + percent).font(.mono(10, .bold)).foregroundStyle(job.stage.isRunning ? P.accent : P.muted)
              + Text(job.timeLeft.map { " · " + $0 } ?? "").font(.mono(10)).foregroundStyle(P.muted)
            if job.stage.isRunning {
              if job.progress > 0 {
                ProgressView(value: job.progress).tint(P.accent)
              } else {
                ProgressView().progressViewStyle(.linear).tint(P.accent)
              }
            }
            if job.stage == .compressing || job.stage == .swapping {
              Text("Генерировать при этом можно").font(.mono(9)).foregroundStyle(P.muted)
            }
          }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      HStack(spacing: 6) {
        if job.failure != nil {
          SmallButton(title: "Показать файл") { library.reveal(job.source) }
          SmallButton(title: "Повторить") { library.retry(job) }
          // only a loose file from the folder is trashed; for other rows the file stays
          SmallButton(
            title: library.dismissTrashesFile(job) ? "В Корзину" : "Убрать из списка", quiet: true
          ) {
            library.dismiss(job)
          }
        } else if job.stage == .done {
          SmallButton(title: "Понятно", quiet: true) { library.dismiss(job) }
        } else if job.stage == .waiting {
          SmallButton(title: "Убрать", quiet: true) { library.cancel(job) }
        } else if job.origin != .catalog, job.origin != .fileServer {
          SmallButton(title: "Отменить", quiet: true) { library.cancel(job) }
        }
      }
    }
    .padding(.horizontal, 12).padding(.vertical, 10)
    .background(P.panel)
    .overlay(Rectangle().stroke(tint, lineWidth: 1))
  }
}

@available(macOS 26, *)
private struct InstalledRow: View {
  @ObservedObject var s: Studio
  @ObservedObject var library: ModelLibrary
  let model: InstalledModel

  private var _squeezing = SwiftUI.State(initialValue: false)
  private var squeezing: Bool {
    get { _squeezing.wrappedValue }
    nonmutating set { _squeezing.wrappedValue = newValue }
  }

  init(s: Studio, library: ModelLibrary, model: InstalledModel) {
    self.s = s
    self.library = library
    self.model = model
  }

  private var kind: String {
    kindBase + {
      switch model.storage {
      case .mac: return ""
      case .external(let disk): return " · НА ДИСКЕ \(disk.uppercased())"
      case .offline(let disk): return " · ДИСК \(disk.uppercased()) НЕ ПОДКЛЮЧЁН"
      }
    }()
  }

  private var kindBase: String {
    let role = model.role.badge
    if let part = model.part {
      let stock = ModelLibrary.withoutTechnicalTail((part.stock as NSString).deletingPathExtension)
      return part.slot.badge + " · ВМЕСТО " + ModelLibrary.pretty(stock).uppercased()
    }
    return model.familyLabel.isEmpty ? role : role + " · " + model.familyLabel.uppercased()
  }

  var body: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text(model.name).font(.sans(13, .bold)).foregroundStyle(P.ink).lineLimit(1)
          .truncationMode(.middle)
        Text(kind).font(.mono(8, .bold)).tracking(0.9).foregroundStyle(P.muted)
      }
      .frame(width: 230, alignment: .leading)

      Text([model.sizeLabel, model.precision].compactMap { $0 }.joined(separator: " · "))
        .font(.mono(10)).foregroundStyle(P.muted)
        .frame(maxWidth: .infinity, alignment: .leading)

      if model.role == .checkpoint, !model.storage.isOffline {
        let chosen = s.model == model.file
        SmallButton(title: chosen ? "Выбрана" : "Выбрать", strong: !chosen) {
          s.selectModel(model.file)
        }
      }
      ModelMenu(s: s, library: library, model: model) { squeezing = true }
    }
    .padding(.horizontal, 12).padding(.vertical, 10)
    .background(P.panel)
    .overlay(Rectangle().stroke(s.model == model.file ? P.line : P.hair, lineWidth: 1))
    .sheet(isPresented: Binding(get: { squeezing }, set: { squeezing = $0 })) {
      CompressSheet(library: library, model: model)
    }
  }
}

/// What can be done with one installed model, behind the three dots.
@available(macOS 26, *)
private struct ModelMenu: View {
  @ObservedObject var s: Studio
  @ObservedObject var library: ModelLibrary
  let model: InstalledModel
  let squeeze: () -> Void

  var body: some View {
      Menu {
        Button("Показать в Finder") { library.reveal(model) }
        switch model.storage {
        case .mac:
          Button("Перенести на внешний диск") {
            if ModelsFolder.external == nil, !DiskRow.chooseFolder() { return }
            library.moveToDisk([model])
          }
        case .external:
          Button("Вернуть на Mac") { library.bringBack(model) }
        case .offline:
          EmptyView()
        }
        if model.canCompress {
          Button("Сжать…") { squeeze() }
        }
        if Covers.image(for: model.file) != nil {
          Button("Убрать обложку") { s.removeCover(model.file) }
        }
        Divider()
        Button("Удалить", role: .destructive) { library.delete(model) }
      } label: {
        // the whole square is the button, not only the three dots inside it
        Image(systemName: "ellipsis").font(.system(size: 11)).foregroundStyle(P.ink)
          .frame(width: 30, height: 26)
          .overlay(Rectangle().stroke(P.hair, lineWidth: 1))
          .contentShape(Rectangle())
      }
      .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
      .fixedSize()
  }
}

/// A picture or video model as a card: its cover, what it is, the settings saved for it and
/// how long it usually takes here.
@available(macOS 26, *)
private struct ModelCard: View {
  @ObservedObject var s: Studio
  @ObservedObject var library: ModelLibrary
  let model: InstalledModel

  @State private var squeezing = false

  private var chosen: Bool { s.model == model.file || s.videoModel == model.file }

  private var saved: String? {
    guard let r = ModelPrefs.load(model.file) else { return nil }
    return "сохранено: " + RunTimes.steps(r.steps) + String(format: " · CFG %g · ", r.cfg)
      + (Samplers.all.first { $0.0 == r.sampler }?.1 ?? "")
  }

  private var where_: String? {
    switch model.storage {
    case .mac: return nil
    case .external(let disk): return "на диске \(disk)"
    case .offline(let disk): return "диск \(disk) не подключён"
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      cover
        .frame(height: 140).frame(maxWidth: .infinity).clipped()
        .overlay(Rectangle().frame(height: 1).foregroundStyle(P.hair), alignment: .bottom)
      VStack(alignment: .leading, spacing: 5) {
        // every line keeps its height whether it is filled or not, so all cards are one size
        Text(model.name).font(.sans(13, .bold)).foregroundStyle(P.ink).lineLimit(2)
          .truncationMode(.middle).frame(height: 34, alignment: .topLeading)
          .frame(maxWidth: .infinity, alignment: .leading)
          .help(model.file)
        Text(([model.familyLabel.isEmpty ? model.role.badge : model.familyLabel.uppercased()]
          + [model.sizeLabel, model.precision].compactMap { $0 }).joined(separator: " · "))
          .font(.mono(8, .bold)).tracking(0.6).foregroundStyle(P.muted).lineLimit(1)
        Label {
          Text(RunTimes.summary(of: model.file, in: .standard)?.label ?? "время появится после первой генерации")
            .lineLimit(2)
        } icon: { Image(systemName: "clock") }
        .font(.mono(9)).foregroundStyle(P.ink)
        .frame(height: 26, alignment: .topLeading)
        Text(where_ ?? saved ?? "настройки не сохранены")
          .font(.mono(9)).foregroundStyle(P.muted).lineLimit(1).truncationMode(.tail)
          .help(saved ?? "")
        HStack(spacing: 6) {
          if !model.storage.isOffline {
            SmallButton(title: chosen ? "Выбрана" : "Выбрать", strong: !chosen) {
              if VideoFamily.isVideo(model.family) { s.selectVideoModel(model.file) } else { s.selectModel(model.file) }
            }
          }
          Spacer(minLength: 0)
          ModelMenu(s: s, library: library, model: model) { squeezing = true }
        }
        .padding(.top, 3)
      }
      .padding(10)
    }
    .background(P.panel)
    .overlay(Rectangle().stroke(chosen ? P.accent : P.hair, lineWidth: chosen ? 2 : 1))
    .sheet(isPresented: $squeezing) { CompressSheet(library: library, model: model) }
  }

  @ViewBuilder private var cover: some View {
    let _ = s.coverStamp
    if let image = Covers.image(for: model.file) {
      Image(nsImage: image).resizable().scaledToFill()
    } else {
      ZStack {
        P.panel2
        VStack(spacing: 6) {
          Text(model.familyLabel.isEmpty ? "?" : model.familyLabel)
            .font(.mono(15, .bold)).tracking(1).foregroundStyle(P.muted)
          Text("обложка: кнопка ✓ на своей картинке")
            .font(.mono(8)).foregroundStyle(P.muted.opacity(0.8))
        }
      }
    }
  }
}

/// The engine's own catalog, with downloads going through the same queue as everything else.
@available(macOS 26, *)
private struct CatalogPane: View {
  @ObservedObject var s: Studio
  @ObservedObject var library: ModelLibrary
  @ObservedObject var c: Catalog

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        HStack(spacing: 8) {
          Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(P.muted)
          TextField("Найти", text: $c.query).textFieldStyle(.plain).font(.mono(11))
        }
        .padding(.horizontal, 10).frame(height: 32)
        .background(P.panel).overlay(Rectangle().stroke(P.line, lineWidth: 1))

        Menu {
          Button("Все семейства") { c.family = nil }
          Divider()
          ForEach(c.families, id: \.self) { f in
            Button(FamilyNames.short(f)) { c.family = f }
          }
        } label: {
          DropLabel(title: c.family.map { FamilyNames.short($0) } ?? "Все семейства", strong: true)
        }
        .menuStyle(.button).buttonStyle(.plain)
        .frame(width: 190)

        SmallButton(title: "Обновить", quiet: true) { Task { await c.load() } }
      }
      .padding(16)

      HStack(spacing: 6) {
        CatChip(title: "Все", on: c.kind == nil && !c.videoOnly) {
          c.kind = nil
          c.videoOnly = false
        }
        CatChip(title: "видео", on: c.videoOnly) {
          c.videoOnly.toggle()
          c.kind = nil
        }
        ForEach(ModelKind.allCases, id: \.self) { k in
          CatChip(title: k.label, on: c.kind == k) {
            c.kind = k
            c.videoOnly = false
          }
        }
        Spacer()
        Text("\(c.filtered.count)").font(.mono(9)).foregroundStyle(P.muted)
      }
      .padding(.horizontal, 16).padding(.bottom, 12)

      if c.loading {
        VStack { Spacer(); Cap(text: "загружаю каталог", rule: false); Spacer() }
      } else if c.all.isEmpty {
        VStack { Spacer(); Text("Каталог не загрузился, проверьте сеть").font(.sans(13)).foregroundStyle(P.muted); Spacer() }
      } else {
        ScrollView {
          LazyVStack(spacing: 8) {
            ForEach(c.filtered) { m in
              CatalogCard(s: s, library: library, model: m)
            }
          }
          .padding(.horizontal, 16).padding(.bottom, 16)
        }
      }
    }
    .task { if c.all.isEmpty { await c.load() } }
  }
}

@available(macOS 26, *)
private struct CatalogCard: View {
  @ObservedObject var s: Studio
  @ObservedObject var library: ModelLibrary
  let model: CatalogEntry

  private var job: ImportJob? { library.jobs.first { $0.catalogEntry?.file == model.file } }
  private var installed: Bool {
    library.installed.contains { $0.file == model.file }
  }

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 8) {
          Text(model.name).font(.sans(13, .bold)).foregroundStyle(P.ink)
          Text(FamilyNames.short(model.family).uppercased()).font(.mono(8, .bold)).tracking(0.8)
            .foregroundStyle(P.muted)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .overlay(Rectangle().stroke(P.hair, lineWidth: 1))
          Text(model.kind.label.uppercased()).font(.mono(8, .bold)).tracking(0.6)
            .foregroundStyle(P.accentText)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .overlay(Rectangle().stroke(P.accent.opacity(0.4), lineWidth: 1))
          if !model.sizeLabel.isEmpty {
            Text(model.sizeLabel).font(.mono(9, .semibold)).foregroundStyle(P.ink)
          }
        }
        if !Describe.family(model.family).isEmpty {
          Text(Describe.family(model.family))
            .font(.mono(9)).tracking(0.2).foregroundStyle(P.muted)
            .fixedSize(horizontal: false, vertical: true)
        }
        ForEach(Describe.suffixes(model.file), id: \.self) { line in
          Text("· " + line)
            .font(.mono(9)).tracking(0.2).foregroundStyle(P.ink.opacity(0.7))
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 8)
      Group {
        if installed {
          SmallButton(title: s.model == model.file ? "Выбрана" : "Выбрать", strong: s.model != model.file) {
            s.selectModel(model.file)
          }
        } else if let job {
          if job.failure != nil {
            SmallButton(title: "Повторить") { library.retry(job) }
          } else {
            Text(job.stage == .waiting ? "В ОЧЕРЕДИ" : "СКАЧИВАЮ · \(Int(job.progress * 100))%")
              .font(.mono(9, .bold)).tracking(0.8).foregroundStyle(P.accentText)
          }
        } else {
          SmallButton(title: "Скачать", strong: true) { library.download(model) }
        }
      }
      .frame(width: 130, alignment: .trailing)
    }
    .padding(13)
    .background(P.panel)
    .overlay(Rectangle().stroke(installed ? P.line : P.hair, lineWidth: 1))
    .task { s.catalog.measure(model.file) }
  }
}

/// A compact bordered text button for rows, where a full hardware button would shout.
@available(macOS 26, *)
struct SmallButton: View {
  let title: String
  var strong = false
  var quiet = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(title.uppercased())
        .font(.mono(9, .bold)).tracking(0.8)
        .foregroundStyle(strong ? P.accentInk : (quiet ? P.muted : P.ink))
        .padding(.horizontal, 10).frame(height: 26)
        .background(strong ? P.accent : P.panel)
        .overlay(Rectangle().stroke(strong ? P.accent : (quiet ? P.hair : P.line), lineWidth: 1))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .fixedSize()
  }
}

@available(macOS 26, *)
struct CatChip: View {
  let title: String
  let on: Bool
  let tap: () -> Void

  var body: some View {
    Button(action: tap) {
      Text(title.uppercased())
        .font(.mono(9, on ? .bold : .regular)).tracking(0.9)
        .foregroundStyle(on ? P.accentInk : P.muted)
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(on ? P.accent : P.panel)
        .overlay(Rectangle().stroke(on ? P.accent : P.line, lineWidth: 1))
    }
    .buttonStyle(.plain)
    .fixedSize()
  }
}

/// Squeezing one model: a preset or a plan of its own, what it will weigh, and whether the
/// original stays.
@available(macOS 26, *)
private struct CompressSheet: View {
  @ObservedObject var library: ModelLibrary
  let model: InstalledModel
  @Environment(\.dismiss) private var dismiss

  private var _plan = SwiftUI.State(initialValue: CompressionPlan.presets[3].plan)
  private var plan: CompressionPlan {
    get { _plan.wrappedValue }
    nonmutating set { _plan.wrappedValue = newValue }
  }
  private var _keep = SwiftUI.State(initialValue: false)
  private var keep: Bool {
    get { _keep.wrappedValue }
    nonmutating set { _keep.wrappedValue = newValue }
  }
  private var _estimate = SwiftUI.State<Int64?>(initialValue: nil)
  private var estimate: Int64? {
    get { _estimate.wrappedValue }
    nonmutating set { _estimate.wrappedValue = newValue }
  }

  init(library: ModelLibrary, model: InstalledModel) {
    self.library = library
    self.model = model
    if WeightCompressor.isUNet(model.family) {
      _plan = SwiftUI.State(initialValue: CompressionPlan(bits: 6, importantBits: 8, edgeBlocks: 1))
    }
  }

  private var unet: Bool { WeightCompressor.isUNet(model.family) }
  private let bitsChoices = [8, 6, 5, 4, 3]

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("СЖАТЬ «\(model.name)»").font(.mono(11, .bold)).tracking(1).foregroundStyle(P.ink)
      Text("сейчас \(model.sizeLabel)" + (model.precision.map { " · \($0)" } ?? ""))
        .font(.mono(10)).foregroundStyle(P.muted)

      VStack(alignment: .leading, spacing: 4) {
        ForEach(CompressionPlan.presets, id: \.name) { preset in
          if !unet || preset.plan.bits >= 6 {
            Button { plan = preset.plan } label: {
              HStack(spacing: 8) {
                Image(systemName: plan == preset.plan ? "largecircle.fill.circle" : "circle")
                  .font(.system(size: 11)).foregroundStyle(plan == preset.plan ? P.accent : P.muted)
                Text(preset.name).font(.mono(10, .bold)).foregroundStyle(P.ink)
                Text(preset.hint).font(.mono(9)).foregroundStyle(P.muted)
                Spacer()
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
        }
      }

      // the plan itself, for whoever wants to set it by hand
      VStack(alignment: .leading, spacing: 8) {
        Cap(text: "своё")
        row("основная точность") {
          bitsMenu(plan.bits) { value in
            var next = plan
            next.bits = value
            next.importantBits = max(next.importantBits, value)
            plan = next
          }
        }
        row("важные слои") {
          bitsMenu(plan.importantBits, floor: plan.bits) { value in
            var next = plan
            next.importantBits = value
            plan = next
          }
        }
        row("модуляция — к важным") {
          LilSwitch(isOn: Binding(get: { plan.raiseModulation }, set: { v in var n = plan; n.raiseModulation = v; plan = n }))
            .scaleEffect(0.7)
        }
        row("первых и последних блоков — к важным") {
          Stepper(
            "\(plan.edgeBlocks)",
            value: Binding(get: { plan.edgeBlocks }, set: { v in var n = plan; n.edgeBlocks = v; plan = n }),
            in: 0...6
          )
          .font(.mono(10)).fixedSize()
        }
        Text(
          unet
            ? "SD 1.5 и SDXL: не ниже 6 бит — меньше их чтение в движке не берёт"
            : "ниже 8 бит идут только матрицы с шириной, кратной 256; остальные остаются в 8 битах. Вход и выход модели всегда 16 бит"
        )
        .font(.mono(9)).tracking(0.2).foregroundStyle(P.muted)
        .fixedSize(horizontal: false, vertical: true)
      }

      Toggle(isOn: Binding(get: { keep }, set: { keep = $0 })) {
        Text("оставить и исходник (иначе сжатая копия займёт его место)").font(.mono(10))
      }
      .toggleStyle(.checkbox).controlSize(.small)

      HStack {
        Text(estimate.map { String(format: "получится ≈ %.1f ГБ", Double($0) / 1_073_741_824) } ?? "считаю размер…")
          .font(.mono(10, .bold)).foregroundStyle(P.ink)
        Spacer()
        SmallButton(title: "отмена") { dismiss() }
        SmallButton(title: "сжать", strong: true) {
          library.compress(model, plan: plan, keepOriginal: keep)
          dismiss()
        }
      }
    }
    .padding(20)
    .frame(width: 520)
    .background(P.bg)
    .task(id: plan) {
      estimate = nil
      let input = library.modelsDir.appendingPathComponent(model.file).path
      let family = model.family
      let wanted = plan
      estimate = await Task.detached(priority: .utility) {
        WeightCompressor.estimate(input: input, version: family, plan: wanted)
      }.value
    }
  }

  private func row<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
    HStack {
      Text(title).font(.mono(10)).foregroundStyle(P.ink)
      Spacer()
      content()
    }
  }

  private func bitsMenu(_ value: Int, floor: Int = 0, _ set: @escaping (Int) -> Void) -> some View {
    Menu {
      ForEach(bitsChoices.filter { $0 >= floor && (!unet || $0 >= 6) }, id: \.self) { bits in
        Button(bits == value ? "✓  \(bits) бит" : "\(bits) бит") { set(bits) }
      }
    } label: {
      DropLabel(title: "\(value) бит")
    }
    .menuStyle(.button).buttonStyle(.plain).fixedSize()
  }
}

/// The external disk models are moved to: which folder, and moving several at once.
@available(macOS 26, *)
private struct DiskRow: View {
  @ObservedObject var library: ModelLibrary

  private var _picking = SwiftUI.State(initialValue: false)
  private var picking: Bool {
    get { _picking.wrappedValue }
    nonmutating set { _picking.wrappedValue = newValue }
  }
  private var _tick = SwiftUI.State(initialValue: 0)

  init(library: ModelLibrary) { self.library = library }

  /// Asks for the folder on the external disk; false when nothing was chosen.
  @discardableResult
  static func chooseFolder() -> Bool {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = URL(fileURLWithPath: "/Volumes")
    panel.message = "папка на внешнем диске, куда переносить модели"
    panel.prompt = "Выбрать"
    guard panel.runModal() == .OK, let url = panel.urls.first else { return false }
    ModelsFolder.setExternal(url)
    return true
  }

  var body: some View {
    let external = ModelsFolder.external
    let reachable = external.map(ModelsFolder.isReachable) ?? false
    let onDisk = library.installed.filter { $0.storage.isExternal }
    HStack(spacing: 10) {
      Image(systemName: "externaldrive").font(.system(size: 11)).foregroundStyle(P.muted)
      VStack(alignment: .leading, spacing: 2) {
        Text(external.map { "внешний диск: " + $0.path } ?? "внешний диск не выбран")
          .font(.mono(10)).foregroundStyle(P.ink).lineLimit(1).truncationMode(.middle)
        Text(
          external == nil
            ? "модели можно держать на внешнем диске: на Mac остаётся ярлык, работают, пока диск подключён"
            : (reachable ? "подключён" : "не подключён") + (onDisk.isEmpty ? "" : " · моделей на нём: \(onDisk.count)")
        )
        .font(.mono(9)).foregroundStyle(P.muted).lineLimit(2)
      }
      Spacer(minLength: 8)
      SmallButton(title: external == nil ? "выбрать папку…" : "сменить…") {
        Self.chooseFolder()
        _tick.wrappedValue += 1
      }
      if external != nil, reachable {
        SmallButton(title: "перенести на диск…", strong: true) { picking = true }
      }
    }
    .padding(.horizontal, 12).padding(.vertical, 8)
    .background(P.panel)
    .overlay(Rectangle().stroke(P.hair, lineWidth: 1))
    .sheet(isPresented: Binding(get: { picking }, set: { picking = $0 })) {
      MoveSheet(library: library)
    }
  }
}

/// Choosing which models go to the external disk, with what that frees on the Mac.
@available(macOS 26, *)
private struct MoveSheet: View {
  @ObservedObject var library: ModelLibrary
  @Environment(\.dismiss) private var dismiss

  private var _chosen = SwiftUI.State(initialValue: Set<String>())
  private var chosen: Set<String> {
    get { _chosen.wrappedValue }
    nonmutating set { _chosen.wrappedValue = newValue }
  }

  init(library: ModelLibrary) { self.library = library }

  private var local: [InstalledModel] {
    library.installed.filter { $0.storage == .mac }.sorted { $0.bytes > $1.bytes }
  }

  var body: some View {
    let picked = local.filter { chosen.contains($0.file) }
    let bytes = library.bytesToMove(picked)
    VStack(alignment: .leading, spacing: 12) {
      Text("ПЕРЕНЕСТИ НА ВНЕШНИЙ ДИСК").font(.mono(11, .bold)).tracking(1).foregroundStyle(P.ink)
      Text("вместе с моделью уходят её кодировщики и VAE, если они не нужны моделям, остающимся на Mac")
        .font(.mono(9)).foregroundStyle(P.muted).fixedSize(horizontal: false, vertical: true)
      ScrollView {
        VStack(alignment: .leading, spacing: 2) {
          ForEach(local) { model in
            Button {
              if chosen.contains(model.file) { chosen.remove(model.file) } else { chosen.insert(model.file) }
            } label: {
              HStack(spacing: 8) {
                Image(systemName: chosen.contains(model.file) ? "checkmark.square.fill" : "square")
                  .foregroundStyle(chosen.contains(model.file) ? P.accent : P.muted)
                Text(model.name).font(.sans(12)).foregroundStyle(P.ink).lineLimit(1)
                Text(model.role.badge).font(.mono(8, .bold)).foregroundStyle(P.muted)
                Spacer()
                Text(model.sizeLabel).font(.mono(10)).foregroundStyle(P.muted)
              }
              .padding(.horizontal, 8).padding(.vertical, 5)
              .background(P.panel).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
        }
      }
      .frame(height: 320)
      HStack {
        Text(picked.isEmpty ? "ничего не выбрано" : String(format: "освободится на Mac ≈ %.1f ГБ", Double(bytes) / 1_073_741_824))
          .font(.mono(10, .bold)).foregroundStyle(P.ink)
        Spacer()
        SmallButton(title: "отмена") { dismiss() }
        SmallButton(title: "перенести", strong: true) {
          library.moveToDisk(picked)
          dismiss()
        }
        .disabled(picked.isEmpty)
      }
    }
    .padding(20)
    .frame(width: 560)
    .background(P.bg)
  }
}
