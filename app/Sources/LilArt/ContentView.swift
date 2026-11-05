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
      PowerModeButton(s: s).padding(.leading, 6)
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
