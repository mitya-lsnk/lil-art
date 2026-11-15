import SwiftUI

// lil art's own parts. The palette, fonts, Cap and LED come from LilKit.swift (lil-kit).

/// Hardware button: sits on a shadow and presses down onto it.
struct HWButton: View {
  let title: String
  var hint: String? = nil
  var symbol: String? = nil
  var primary = false
  var enabled = true
  var fixedWidth: CGFloat? = nil
  var action: () -> Void

  // The macOS 26 SDK turned @State into a macro whose plugin ships only with full
  // Xcode. State itself is still a plain property wrapper, so spell out the storage
  // the macro would have generated.
  private var _down = SwiftUI.State(initialValue: false)
  private var down: Bool {
    get { _down.wrappedValue }
    nonmutating set { _down.wrappedValue = newValue }
  }

  private var height: CGFloat { primary ? 46 : 34 }
  private var lift: CGFloat { primary ? 4 : 3 }

  var body: some View {
    HStack(spacing: 8) {
      if let symbol {
        Image(systemName: symbol).font(.system(size: primary ? 14 : 12, weight: .bold))
      }
      if !title.isEmpty {
        Text(title.uppercased())
          .font(.mono(primary ? 12 : 10, .bold))
          .tracking(1.2)
          // a button's name is one line; a long one shrinks a little rather than wrapping
          .lineLimit(1).minimumScaleFactor(0.75)
      }
      if let hint {
        Text(hint).font(.mono(10)).opacity(0.7)
      }
    }
    .padding(.horizontal, primary ? 18 : 12)
    .frame(width: fixedWidth, height: height)
    .frame(maxWidth: fixedWidth == nil ? .infinity : nil)
    // A disabled key rests pressed down, flat and quiet, rather than a translucent grey that
    // muddies over its own shadow.
    .foregroundStyle(enabled ? (primary ? P.accentInk : P.ink) : P.muted)
    .background(enabled ? (primary ? P.accent : P.panel) : P.panel2)
    .overlay(RoundedRectangle(cornerRadius: 9).stroke(enabled ? P.line : P.hair, lineWidth: 1))
    .clipShape(RoundedRectangle(cornerRadius: 9))
    .offset(y: enabled ? (down ? lift : 0) : lift)
    .background(RoundedRectangle(cornerRadius: 9).fill(enabled ? P.keyShadow : Color.clear).offset(y: lift))
    .contentShape(Rectangle())
    .onTapGesture { if enabled { action() } }
    .gesture(
      DragGesture(minimumDistance: 0)
        .onChanged { _ in if enabled { down = true } }
        .onEnded { _ in down = false })
    .animation(.easeOut(duration: 0.06), value: down)
  }
}

/// A small "i" that opens a plain-language note. Used where a number needs context.
struct InfoDot: View {
  let text: String

  private var _open = SwiftUI.State(initialValue: false)
  private var open: Bool {
    get { _open.wrappedValue }
    nonmutating set { _open.wrappedValue = newValue }
  }

  var body: some View {
    Button { open.toggle() } label: {
      Image(systemName: "info.circle")
        .font(.system(size: 11))
        .foregroundStyle(P.muted)
    }
    .buttonStyle(.plain)
    .popover(isPresented: Binding(get: { open }, set: { open = $0 }), arrowEdge: .bottom) {
      Text(text)
        .font(.mono(10))
        .lineSpacing(2)
        .foregroundStyle(P.ink)
        .fixedSize(horizontal: false, vertical: true)
        .padding(16)
        .frame(width: 300)
        .background(P.panel)
    }
  }
}

/// The label a Menu wears, so a dropdown never reads as plain text: the caret sits in its
/// own boxed compartment behind a rule.
struct DropLabel: View {
  let title: String
  var mono = true
  var size: CGFloat = 10
  var strong = false

  var body: some View {
    HStack(spacing: 0) {
      Text(strong ? title.uppercased() : title)
        .font(mono ? .mono(size, strong ? .bold : .regular) : .sans(size))
        .tracking(mono ? 0.9 : 0)
        .foregroundStyle(P.ink)
        .lineLimit(1)
        .truncationMode(.middle)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
      Rectangle().fill(P.line).frame(width: 1)
      Image(systemName: "chevron.down")
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(P.ink)
        .frame(width: 28)
        .background(P.panel2)
    }
    .frame(height: 34)
    .background(P.panel)
    .overlay(Rectangle().stroke(P.line, lineWidth: 1))
    .contentShape(Rectangle())
  }
}

/// Joined row of mono caps buttons; the selected one fills with accent.
struct Segmented<T: Hashable>: View {
  let options: [(T, String)]
  @Binding var value: T
  var fill = false

  var body: some View {
    HStack(spacing: 0) {
      ForEach(Array(options.enumerated()), id: \.offset) { _, opt in
        let on = opt.0 == value
        Text(opt.1.uppercased())
          .font(.mono(10, on ? .bold : .regular))
          .tracking(1.1)
          .lineLimit(1)
          .fixedSize(horizontal: true, vertical: false)
          .foregroundStyle(on ? P.accentInk : P.muted)
          .padding(.horizontal, 11)
          .padding(.vertical, 8)
          .frame(maxWidth: fill ? .infinity : nil)
          .background(on ? P.accent : P.panel)
          .overlay(Rectangle().stroke(on ? P.accent : P.line, lineWidth: 1))
          .contentShape(Rectangle())
          .onTapGesture { value = opt.0 }
      }
    }
  }
}
