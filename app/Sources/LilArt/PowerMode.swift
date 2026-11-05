import AppKit
import SwiftUI

/// The system's Low Power Mode, shown and switched from the top bar. Reading it is free; turning
/// it on or off is `pmset`, which needs an administrator, so macOS asks in its own window (with
/// Touch ID where it allows that). The app never sees the password.
@MainActor
final class PowerMode: ObservableObject {
  @Published private(set) var isOn = ProcessInfo.processInfo.isLowPowerModeEnabled
  @Published private(set) var switching = false

  private var observer: NSObjectProtocol?

  init() {
    // also when it is switched in Control Center or System Settings
    observer = NotificationCenter.default.addObserver(
      forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.isOn = ProcessInfo.processInfo.isLowPowerModeEnabled }
    }
  }

  /// nil when it switched or the person cancelled; otherwise what went wrong, in words.
  func toggle() async -> String? {
    guard !switching else { return nil }
    switching = true
    defer { switching = false }
    let want = isOn ? 0 : 1
    let script =
      "do shell script \"/usr/bin/pmset -a lowpowermode \(want)\" with prompt \"lil art хочет \(want == 1 ? "включить" : "выключить") режим энергосбережения.\" with administrator privileges"
    let result = await Task.detached { () -> (Int32, String) in
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
      process.arguments = ["-e", script]
      let errors = Pipe()
      process.standardError = errors
      process.standardOutput = Pipe()
      do { try process.run() } catch { return (-1, error.localizedDescription) }
      process.waitUntilExit()
      let text = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
      return (process.terminationStatus, text)
    }.value
    isOn = ProcessInfo.processInfo.isLowPowerModeEnabled
    if result.0 == 0 { return nil }
    if result.1.contains("-128") { return nil }  // the person pressed Cancel
    return "режим энергосбережения не переключился"
  }
}

@available(macOS 26, *)
struct PowerModeButton: View {
  @ObservedObject var s: Studio
  @ObservedObject var power: PowerMode

  init(s: Studio) {
    self.s = s
    self.power = s.power
  }

  var body: some View {
    Button {
      Task {
        if let problem = await power.toggle() { s.status = problem }
      }
    } label: {
      Image(systemName: power.isOn ? "leaf.fill" : "leaf")
        .font(.system(size: 13))
        .foregroundStyle(power.isOn ? P.accent : P.ink)
        .frame(width: 30, height: 30)
        .background(P.panel2)
        .overlay(Rectangle().stroke(P.line, lineWidth: 1))
        .contentShape(Rectangle())
        .opacity(power.switching ? 0.5 : 1)
    }
    .buttonStyle(.plain)
    .help(
      power.isOn
        ? "Режим энергосбережения включён: генерация медленнее, Мак холоднее и тише. Нажмите, чтобы выключить"
        : "Включить режим энергосбережения: генерация станет медленнее, зато Мак меньше греется. macOS спросит пароль или палец"
    )
  }
}
