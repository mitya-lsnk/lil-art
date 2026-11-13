import SwiftUI

@main
struct LilArtApp: App {
  @StateObject private var holder = StudioHolder()

  init() {
    // what the app downloads is kept in the project (data/cache), not in ~/Library/Caches
    LilStore.useProjectCache()
  }

  var body: some Scene {
    Window("lil art", id: "main") {
      if #available(macOS 26, *) {
        ContentView(s: holder.studio)
      } else {
        Text("lil art требует macOS 26")
          .font(.system(size: 15))
          .frame(width: 420, height: 160)
      }
    }
    .defaultSize(width: 1180, height: 760)
    .commands {
      LilCommands()
      CommandGroup(replacing: .newItem) {}
      CommandGroup(replacing: .appSettings) { SettingsCommand() }
    }

    Window("Модели", id: "models") {
      if #available(macOS 26, *) {
        ModelsWindow(s: holder.studio)
      }
    }
    .defaultSize(width: 880, height: 640)

    // an ordinary window rather than the Settings scene, whose toolbar tabs cannot take the
    // studio's look
    Window("Настройки", id: "settings") {
      if #available(macOS 26, *) {
        SettingsView(s: holder.studio)
      }
    }
    .windowResizability(.contentSize)
  }
}

/// "Настройки…" in the app menu with the usual ⌘, opening the settings window.
private struct SettingsCommand: View {
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button("Настройки…") { openWindow(id: "settings") }
      .keyboardShortcut(",", modifiers: .command)
  }
}

/// One studio shared by every window. It is made on first use, because the type exists only
/// on macOS 26 and later.
final class StudioHolder: ObservableObject {
  private var storage: AnyObject?

  @available(macOS 26, *)
  @MainActor
  var studio: Studio {
    if let existing = storage as? Studio { return existing }
    let made = Studio()
    storage = made
    return made
  }
}
