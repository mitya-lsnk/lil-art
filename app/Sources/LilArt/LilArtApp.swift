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
      CommandGroup(replacing: .appSettings) {
        if #available(macOS 26, *) { SettingsCommand(s: holder.studio) }
      }
    }
  }
}

/// "Настройки…" in the app menu with the usual ⌘,: the settings page of the main window.
@available(macOS 26, *)
private struct SettingsCommand: View {
  @ObservedObject var s: Studio

  var body: some View {
    Button("Настройки…") { s.showSettings.toggle() }
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
