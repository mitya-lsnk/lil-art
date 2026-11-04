// lil-kit: shared file — edit ~/lil-kit/swift/LilKit.swift, then run ~/lil-kit/sync.sh
import AppKit
import SwiftUI

// The lil design language for SwiftUI apps: the same skins, modes, type and small parts as
// the web apps (~/lil-kit/web/src/skins.css, dark.css). Every view reads colours through `P`,
// which follows the skin and mode chosen in Settings → Appearance, live.
// Per-app choices (which skins, the default, a neutral photo surround) are in LilApp.swift,
// generated from ~/lil-kit/apps.json.

/// The four suite skins, plus `photo` — neutral greys for apps that judge colour in photos.
enum LilSkin: String, CaseIterable {
  case studio, brutal, riso, te, photo

  var title: String {
    switch self {
    case .studio: "lil studio"
    case .brutal: "Нео-брутализм"
    case .riso: "Рисо-поп"
    case .te: "Девайс"
    case .photo: "Фото"
    }
  }
  /// Two colours for the picker card, the same as the web apps' SKINS.
  var swatch: (Color, Color) {
    switch self {
    case .studio: (Color(hex: 0xff3d0d), Color(hex: 0x2fbf4c))
    case .brutal: (Color(hex: 0xffde00), Color(hex: 0x111111))
    case .riso: (Color(hex: 0xea3a0c), Color(hex: 0x2233c4))
    case .te: (Color(hex: 0xfa4b00), Color(hex: 0x15150f))
    case .photo: (Color(hex: 0xff3d0d), Color(hex: 0x808080))
    }
  }
}

enum LilMode: String { case light, dark }

struct LilScheme {
  let bg, panel, panel2: Color
  let ink, muted, line, hair: Color
  let accent, accentInk: Color
  /// The accent when it colours text on bg/panel. Same as `accent` except where the accent is
  /// too light to read as text (brutal's yellow on cream).
  let accentText: Color
  let led, amber, bad: Color
  /// Dark "screen" inset (previews, readouts).
  let screen: Color
  /// Surround behind a photo. Neutral in every skin, so it can't shift how the picture reads.
  let stage: Color
  let isDark: Bool

  var colorScheme: ColorScheme { isDark ? .dark : .light }
  /// The hard shadow under keys and cards: ink on light grounds; on dark ones a light ink
  /// shadow would read as a glowing slab, so it goes black, as in the web apps' dark mode.
  var keyShadow: Color { isDark ? Color.black.opacity(0.6) : ink }

  // Values are the web tokens: bg=--paper, panel=--surface, panel2=--surface-2, led=--ok,
  // amber=--warn, bad=--danger. hair is the faint rule the web skins draw with opacity.
  private init(_ bg: UInt32, _ panel: UInt32, _ panel2: UInt32, ink: UInt32, muted: UInt32,
               line: UInt32, accent: UInt32, accentInk: UInt32, led: UInt32, amber: UInt32,
               bad: UInt32, screen: UInt32, stage: UInt32, dark: Bool, accentText: UInt32? = nil) {
    self.bg = Color(hex: bg); self.panel = Color(hex: panel); self.panel2 = Color(hex: panel2)
    self.ink = Color(hex: ink); self.muted = Color(hex: muted); self.line = Color(hex: line)
    hair = dark ? Color.white.opacity(0.08) : Color(hex: ink).opacity(0.22)
    self.accent = Color(hex: accent); self.accentInk = Color(hex: accentInk)
    self.accentText = Color(hex: accentText ?? accent)
    self.led = Color(hex: led); self.amber = Color(hex: amber); self.bad = Color(hex: bad)
    self.screen = Color(hex: screen); self.stage = Color(hex: stage); isDark = dark
  }

  private func withStage(_ stage: Color) -> LilScheme { LilScheme(copy: self, stage: stage) }
  private init(copy s: LilScheme, stage: Color) {
    bg = s.bg; panel = s.panel; panel2 = s.panel2; ink = s.ink; muted = s.muted; line = s.line
    hair = s.hair; accent = s.accent; accentInk = s.accentInk; accentText = s.accentText
    led = s.led; amber = s.amber
    bad = s.bad; screen = s.screen; self.stage = stage; isDark = s.isDark
  }

  static func of(_ skin: LilSkin, _ mode: LilMode) -> LilScheme {
    let s: LilScheme
    switch (skin, mode) {
    case (.studio, .light): s = paper
    case (.studio, .dark): s = night
    case (.brutal, .light):
      s = .init(0xf2eee3, 0xffffff, 0xf5f2ea, ink: 0x111111, muted: 0x666666, line: 0x111111,
                accent: 0xffde00, accentInk: 0x111111, led: 0x2fa85a, amber: 0xf5a623, bad: 0xff3ea5,
                screen: 0x111111, stage: 0x2b2b2b, dark: false, accentText: 0x7a5f00)
    case (.brutal, .dark):
      s = .init(0x0e0e0e, 0x1a1a1a, 0x242424, ink: 0xf4f0e6, muted: 0x9a968c, line: 0xf4f0e6,
                accent: 0xffde00, accentInk: 0x111111, led: 0x2fa85a, amber: 0xf5a623, bad: 0xff5bb0,
                screen: 0x000000, stage: 0x0a0a0a, dark: true)
    case (.riso, .light):
      s = .init(0xf5ebd8, 0xf5ebd8, 0xf2e6d0, ink: 0x1a1712, muted: 0x8a7e68, line: 0x1a1712,
                accent: 0xea3a0c, accentInk: 0xf5ebd8, led: 0x2fa85a, amber: 0xf5a623, bad: 0xea3a0c,
                screen: 0x1a1712, stage: 0x2b2721, dark: false)
    case (.riso, .dark):
      s = .init(0x17130d, 0x1e1913, 0x251f16, ink: 0xf2e6cf, muted: 0xa1927a, line: 0xf2e6cf,
                accent: 0xff5a2c, accentInk: 0x17130d, led: 0x2fa85a, amber: 0xf5a623, bad: 0xff5a2c,
                screen: 0x0e0b07, stage: 0x16120d, dark: true)
    case (.te, .light):
      s = .init(0xe4e3de, 0xedece6, 0xeae9e3, ink: 0x1e1e1b, muted: 0x8a897f, line: 0xd3d2cc,
                accent: 0xfa4b00, accentInk: 0x241000, led: 0x2fa85a, amber: 0xf5a623, bad: 0xfa4b00,
                screen: 0x15150f, stage: 0x24241f, dark: false)
    case (.te, .dark):
      s = .init(0x232420, 0x2c2d27, 0x313229, ink: 0xe8e6da, muted: 0x909084, line: 0x3c3d35,
                accent: 0xfa4b00, accentInk: 0x1a0a00, led: 0x35b565, amber: 0xf5a623, bad: 0xfa4b00,
                screen: 0x0d0d0a, stage: 0x1a1b17, dark: true)
    case (.photo, .light): s = photoLight
    case (.photo, .dark): s = photo
    }
    // Apps that judge colour in photos keep the photo surround neutral whatever the skin.
    if LilApp.neutralStage { return s.withStage((mode == .dark ? photo : photoLight).stage) }
    return s
  }

  /// Studio, light: warm paper, ink hairlines, vermilion. The suite default.
  static let paper = LilScheme(
    0xe7e4da, 0xf3f1e9, 0xebe8de, ink: 0x17150f, muted: 0x6c6a5f, line: 0x17150f,
    accent: 0xff3d0d, accentInk: 0xffffff, led: 0x2fbf4c, amber: 0xffb000, bad: 0xff4f9a,
    screen: 0x000000, stage: 0x2a2823, dark: false)

  /// Studio, dark — the web apps' [data-mode="dark"][data-skin="studio"].
  static let night = LilScheme(
    0x100f0c, 0x191712, 0x141210, ink: 0xf1efe4, muted: 0x8d897c, line: 0x3a362c,
    accent: 0xff5a1f, accentInk: 0x120c07, led: 0x3ee06a, amber: 0xffb000, bad: 0xff5da2,
    screen: 0x0b0a08, stage: 0x131211, dark: true)

  /// Neutral dark (lil develop's own look): studio parts and accent on grey grounds.
  static let photo = LilScheme(
    0x161616, 0x1f1f1f, 0x292929, ink: 0xe9e7e0, muted: 0x8b8982, line: 0x3a3a3a,
    accent: 0xff3d0d, accentInk: 0xffffff, led: 0x2fbf4c, amber: 0xffb000, bad: 0xff4d3a,
    screen: 0x000000, stage: 0x262626, dark: true)

  /// Neutral light: the same idea on light greys; the photo sits on middle grey.
  static let photoLight = LilScheme(
    0xdcdcdc, 0xe8e8e8, 0xd2d2d2, ink: 0x1b1b1b, muted: 0x666666, line: 0xb4b4b4,
    accent: 0xff3d0d, accentInk: 0xffffff, led: 0x2fa85a, amber: 0xf5a623, bad: 0xe0321e,
    screen: 0x000000, stage: 0x7a7a7a, dark: false)
}

/// The chosen skin and mode, remembered in the app's defaults. Views don't watch this object
/// themselves: reading `P` inside a body is enough, because the getter reports the access to
/// SwiftUI's observation (written by hand — the @Observable macro needs Xcode's plugins).
final class LilAppearance: @unchecked Sendable {
  static let shared = LilAppearance()

  private let registrar: Any?
  private var _skin: LilSkin
  private var _mode: LilMode
  private var _scheme: LilScheme

  private init() {
    if #available(macOS 14, *) { registrar = ObservationRegistrar() } else { registrar = nil }
    let d = UserDefaults.standard
    let stored = d.string(forKey: "lil.skin").flatMap(LilSkin.init(rawValue:))
    _skin = stored.flatMap { LilApp.skins.contains($0) ? $0 : nil } ?? LilApp.defaultSkin
    // No stored choice → follow the system, as the web apps do. An explicit choice wins.
    _mode = d.string(forKey: "lil.mode").flatMap(LilMode.init(rawValue:))
      ?? LilApp.defaultMode
      ?? (d.string(forKey: "AppleInterfaceStyle") == "Dark" ? .dark : .light)
    _scheme = .of(_skin, _mode)
  }

  var skin: LilSkin {
    get { track(); return _skin }
    set { change { _skin = newValue; UserDefaults.standard.set(newValue.rawValue, forKey: "lil.skin") } }
  }
  var mode: LilMode {
    get { track(); return _mode }
    set { change { _mode = newValue; UserDefaults.standard.set(newValue.rawValue, forKey: "lil.mode") } }
  }
  var scheme: LilScheme { track(); return _scheme }

  func toggleMode() { mode = mode == .dark ? .light : .dark }

  private func track() {
    if #available(macOS 14, *), let r = registrar as? ObservationRegistrar { r.access(self, keyPath: \.scheme) }
  }
  private func change(_ body: () -> Void) {
    if #available(macOS 14, *), let r = registrar as? ObservationRegistrar {
      r.withMutation(of: self, keyPath: \.scheme) { body(); _scheme = .of(_skin, _mode) }
    } else {
      body(); _scheme = .of(_skin, _mode)
    }
  }
}

@available(macOS 14, *)
extension LilAppearance: Observable {}

/// The current colours. Read it inside `body`, never cache it in a `static let`.
var P: LilScheme { LilAppearance.shared.scheme }

extension View {
  /// Put on each window's root: matches system controls (menus, text fields, scroll bars) to
  /// the chosen mode. Replaces a fixed `.environment(\.colorScheme, .light)`.
  func lilAppearance() -> some View { modifier(LilAppearanceRoot()) }
}

private struct LilAppearanceRoot: ViewModifier {
  func body(content: Content) -> some View {
    content.environment(\.colorScheme, P.colorScheme).background(P.bg)
  }
}

extension Color {
  init(hex: UInt32) {
    self.init(.sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
              blue: Double(hex & 0xff) / 255, opacity: 1)
  }
}

extension Font {
  /// Helvetica Neue by PostScript name: asking for the family and then applying .bold makes
  /// the system synthesise a smeared bold.
  static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
    switch weight {
    case .bold, .heavy, .black: return .custom("HelveticaNeue-Bold", size: size)
    case .semibold, .medium: return .custom("HelveticaNeue-Medium", size: size)
    case .light, .thin, .ultraLight: return .custom("HelveticaNeue-Light", size: size)
    default: return .custom("HelveticaNeue", size: size)
    }
  }
  static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
    .system(size: size, weight: weight, design: .monospaced)
  }
}

/// `@State` for builds without full Xcode: the macOS 26 SDK made @State a macro whose plugin
/// ships only with Xcode, but SwiftUI.State itself is still a property wrapper we can nest.
@propertyWrapper
struct Local<Value>: DynamicProperty {
  private var state: SwiftUI.State<Value>
  init(wrappedValue: Value) { state = SwiftUI.State(initialValue: wrappedValue) }
  var wrappedValue: Value {
    get { state.wrappedValue }
    nonmutating set { state.wrappedValue = newValue }
  }
  var projectedValue: Binding<Value> { state.projectedValue }
}

/// Section label: a short rule, then mono caps with wide tracking.
struct Cap: View {
  let text: String
  var rule = true
  var color: Color = P.muted
  var body: some View {
    HStack(spacing: 9) {
      if rule { Rectangle().fill(P.ink.opacity(0.45)).frame(width: 20, height: 1) }
      Text(text.uppercased()).font(.mono(10, .bold)).tracking(1.6).foregroundStyle(color)
    }
  }
}

/// Indicator lamp with a matching glow ring.
struct LED: View {
  var color: Color = P.led
  var body: some View {
    Circle().fill(color).frame(width: 8, height: 8)
      .overlay(Circle().stroke(color.opacity(0.35), lineWidth: 3)).padding(3)
  }
}

/// The suite's menu-bar items, the same in every SwiftUI lil app (the web apps get theirs
/// from menu.rs): "About" opens the standard panel signed "lil software", and the empty
/// Help item SwiftUI adds by default ("Help isn't available") is removed — or, when the app
/// has a public repository, replaced by a link to it.
///
///   .commands { LilCommands(); /* app's own CommandGroup/CommandMenu */ }
struct LilCommands: Commands {
  var body: some Commands {
    CommandGroup(replacing: .appInfo) {
      Button("О программе \(LilApp.name)") {
        NSApp.orderFrontStandardAboutPanel(options: [
          .credits: NSAttributedString(
            string: "lil software",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]),
        ])
        // lil art builds inside a package that still targets macOS 13
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
      }
    }
    CommandGroup(replacing: .help) {
      if let repo = LilApp.repo, let url = URL(string: "https://github.com/\(repo)") {
        Button("Страница программы на GitHub") { NSWorkspace.shared.open(url) }
      }
    }
  }
}

// MARK: - Settings window

// Settings in every SwiftUI lil app: a row of tabs, the app's own subjects first, then
// «Оформление» and «О программе» last — the order of lil edit and lil download.
//
//   LilSettingsTabs(tabs: [(.general, "Общие", "gearshape"), …, LilSettingsTab.look(.look),
//                          LilSettingsTab.about(.about)], selection: $page)
//   switch page { …; case .look: LilAppearanceSettings(); case .about: LilAboutSettings(…) }

enum LilSettingsTab {
  static func look<T>(_ id: T) -> (T, String, String) { (id, "Оформление", "paintpalette") }
  static func about<T>(_ id: T) -> (T, String, String) { (id, "О программе", "info.circle") }
}

/// The tab row: mono caps, the active tab filled with the accent.
struct LilSettingsTabs<Tab: Hashable>: View {
  let tabs: [(Tab, String, String)]
  @Binding var selection: Tab

  var body: some View {
    HStack(spacing: 0) {
      ForEach(Array(tabs.enumerated()), id: \.offset) { _, item in
        let on = item.0 == selection
        Button { selection = item.0 } label: {
          HStack(spacing: 7) {
            Image(systemName: item.2).font(.system(size: 11, weight: .semibold))
            Text(item.1.uppercased()).font(.mono(10, on ? .bold : .regular)).tracking(1.1)
              .lineLimit(1).minimumScaleFactor(0.8)
          }
          .foregroundStyle(on ? P.accentInk : P.ink)
          .frame(maxWidth: .infinity).frame(height: 34)
          .background(on ? P.accent : P.panel)
          .overlay(Rectangle().stroke(on ? P.accent : P.line, lineWidth: 1))
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, 18).padding(.vertical, 14)
    .background(P.panel)
    .overlay(Rectangle().frame(height: 1).foregroundStyle(P.line), alignment: .bottom)
  }
}

/// One scrolling page under the tabs.
struct LilSettingsPage<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) { content }
        .padding(.horizontal, 22).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(P.bg)
  }
}

/// A setting on one line: what it is on the left, the control on the right, a short note under
/// it only when it helps.
struct LilSettingRow<Control: View>: View {
  let title: String
  var note: String? = nil
  @ViewBuilder var control: Control

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(alignment: .center, spacing: 12) {
        Text(title).font(.sans(13)).foregroundStyle(P.ink)
        Spacer(minLength: 12)
        control
      }
      if let note {
        Text(note).font(.sans(11)).foregroundStyle(P.muted)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.vertical, 10)
    .overlay(Rectangle().frame(height: 1).foregroundStyle(P.hair), alignment: .bottom)
  }
}

/// The suite's switch: the accent colour instead of the system blue.
struct LilSwitch: View {
  @Binding var isOn: Bool

  var body: some View {
    Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).tint(P.accent)
  }
}

/// Settings → Оформление: light/dark and the skin, applied live.
struct LilAppearanceSettings: View {
  var body: some View {
    let look = LilAppearance.shared
    LilSettingsPage {
      Text("Стиль меняет весь интерфейс — цвета, линии и акценты. Выбор запоминается.")
        .font(.sans(12)).foregroundStyle(P.muted)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 10)

      Cap(text: "Тема").padding(.top, 8).padding(.bottom, 8)
      HStack(spacing: 0) {
        ForEach([(LilMode.light, "Светлая", "sun.max"), (.dark, "Тёмная", "moon")], id: \.0) { m in
          let on = look.mode == m.0
          Button { look.mode = m.0 } label: {
            HStack(spacing: 6) {
              Image(systemName: m.2).font(.system(size: 11, weight: .semibold))
              Text(m.1.uppercased()).font(.mono(10, on ? .bold : .regular)).tracking(1.1)
            }
            .foregroundStyle(on ? P.accentInk : P.ink)
            .frame(width: 130, height: 30)
            .background(on ? P.accent : P.panel)
            .overlay(Rectangle().stroke(on ? P.accent : P.line, lineWidth: 1))
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
      }

      Cap(text: "Стиль").padding(.top, 18).padding(.bottom, 8)
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10)], alignment: .leading, spacing: 10) {
        ForEach(LilApp.skins, id: \.self) { skin in
          let on = look.skin == skin
          Button { look.skin = skin } label: {
            VStack(alignment: .leading, spacing: 10) {
              HStack(spacing: 4) {
                Circle().fill(skin.swatch.0).frame(width: 14, height: 14)
                Circle().fill(skin.swatch.1).frame(width: 14, height: 14)
                  .overlay(Circle().stroke(P.line.opacity(0.4), lineWidth: 1))
                Spacer()
                if on { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)) }
              }
              Text(skin.title).font(.sans(12, on ? .bold : .regular)).lineLimit(1)
            }
            .foregroundStyle(P.ink)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(P.panel)
            .overlay(Rectangle().stroke(on ? P.accent : P.line, lineWidth: on ? 2 : 1))
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
      }
    }
  }
}

/// Settings → О программе: icon, name, version, what the app is for, who made it.
struct LilAboutSettings<Extra: View>: View {
  let description: String
  @ViewBuilder var extra: Extra

  init(description: String, @ViewBuilder extra: () -> Extra = { EmptyView() }) {
    self.description = description
    self.extra = extra()
  }

  var body: some View {
    let info = Bundle.main.infoDictionary ?? [:]
    let version = info["CFBundleShortVersionString"] as? String ?? "—"
    LilSettingsPage {
      HStack(alignment: .center, spacing: 16) {
        Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
        VStack(alignment: .leading, spacing: 4) {
          Text(LilApp.name).font(.sans(22, .bold)).foregroundStyle(P.ink)
          Text("ВЕРСИЯ \(version)").font(.mono(10, .bold)).tracking(1.4).foregroundStyle(P.muted)
        }
      }
      .padding(.vertical, 14)

      Text(description).font(.sans(13)).foregroundStyle(P.ink)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, 12)

      extra

      if let repo = LilApp.repo, let url = URL(string: "https://github.com/\(repo)") {
        LilSettingRow(title: "Страница программы") {
          Button("GitHub") { NSWorkspace.shared.open(url) }
        }
      }
      Cap(text: "lil software", rule: true).padding(.top, 18)
    }
  }
}
