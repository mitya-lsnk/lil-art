import AppKit
import SwiftUI

/// The prompt field, built on the native macOS text view because that one already knows
/// how to underline misspellings and how to show a completion list — the same ones Notes
/// and Pages use, with arrows, Return and Esc working out of the box.
@available(macOS 26, *)
struct PromptTextView: NSViewRepresentable {
  @Binding var text: String
  var fontSize: CGFloat = 13
  let assist: PromptAssist
  var useHistory = true

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.borderType = .noBorder
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true

    let view = CompletingTextView()
    view.coordinator = context.coordinator
    view.delegate = context.coordinator
    view.isRichText = false
    view.allowsUndo = true
    view.drawsBackground = false
    view.font = NSFont(name: "HelveticaNeue", size: fontSize) ?? .systemFont(ofSize: fontSize)
    view.textColor = NSColor(P.ink)
    view.insertionPointColor = NSColor(P.ink)
    view.textContainerInset = NSSize(width: 4, height: 6)

    // Prompts are not prose: smart quotes, dashes and silent auto-correction all break
    // tags and weights without anyone noticing.
    view.isAutomaticQuoteSubstitutionEnabled = false
    view.isAutomaticDashSubstitutionEnabled = false
    view.isAutomaticTextReplacementEnabled = false
    view.isAutomaticSpellingCorrectionEnabled = false
    view.isGrammarCheckingEnabled = false
    view.isContinuousSpellCheckingEnabled = assist.spellcheck

    view.isVerticallyResizable = true
    view.isHorizontallyResizable = false
    view.autoresizingMask = [.width]
    view.minSize = .zero
    view.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    view.textContainer?.widthTracksTextView = true
    view.textContainer?.containerSize = NSSize(
      width: 0, height: CGFloat.greatestFiniteMagnitude)
    view.string = text

    scroll.documentView = view
    return scroll
  }

  /// The field goes away with its undo steps (see `TextUndo`): left behind in the window's
  /// history, they made ⌘Z call a freed object.
  static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
    if let view = scroll.documentView as? NSTextView { TextUndo.forget(view) }
  }

  /// The field takes the width it is offered and the height it is given, whatever the text in
  /// it measures: a long line must never widen the sidebar it sits in.
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
    CGSize(width: proposal.width ?? 300, height: proposal.height ?? 104)
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    context.coordinator.parent = self
    guard let view = scroll.documentView as? CompletingTextView else { return }
    if view.string != text {
      let caret = view.selectedRange().location
      view.string = text
      let length = (text as NSString).length
      view.setSelectedRange(NSRange(location: Swift.min(caret, length), length: 0))
      context.coordinator.lastLength = length
    }
    if view.isContinuousSpellCheckingEnabled != assist.spellcheck {
      view.isContinuousSpellCheckingEnabled = assist.spellcheck
    }
    // AppKit keeps the colours it was given, so they are handed over again on every update:
    // that is how a change of skin or of light/dark reaches the text, caret and scroller.
    let ink = NSColor(P.ink)
    if view.textColor != ink {
      view.textColor = ink
      view.insertionPointColor = ink
    }
    let appearance = NSAppearance(named: P.isDark ? .darkAqua : .aqua)
    if scroll.appearance?.name != appearance?.name { scroll.appearance = appearance }
  }

  @MainActor
  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: PromptTextView
    var lastLength: Int
    var skipNextTrigger = false
    fileprivate var pending: [Suggestion] = []
    fileprivate var byLabel: [String: Suggestion] = [:]

    init(_ parent: PromptTextView) {
      self.parent = parent
      lastLength = (parent.text as NSString).length
    }

    func textDidChange(_ notification: Notification) {
      guard let view = notification.object as? CompletingTextView else { return }
      let current = view.string
      parent.text = current

      let length = (current as NSString).length
      let grew = length > lastLength
      lastLength = length
      if skipNextTrigger {
        skipNextTrigger = false
        return
      }
      // Only while typing forward; deleting should never pop a list up.
      guard grew else { return }

      let range = view.rangeForUserCompletion
      guard range.location != NSNotFound, range.length >= 2 else { return }
      let token = (current as NSString).substring(with: range)
      let found = parent.assist.suggestions(for: token, includeHistory: parent.useHistory)
      // Asking for completions with nothing to show makes the system beep.
      guard !found.isEmpty else { return }
      pending = found
      DispatchQueue.main.async { [weak view] in view?.complete(nil) }
    }

    func textView(
      _ textView: NSTextView, completions words: [String], forPartialWordRange charRange: NSRange,
      indexOfSelectedItem index: UnsafeMutablePointer<Int>?
    ) -> [String] {
      var list = pending
      pending = []
      if list.isEmpty {
        let token = (textView.string as NSString).substring(with: charRange)
        list = parent.assist.suggestions(for: token, includeHistory: parent.useHistory)
      }
      byLabel = [:]
      var labels: [String] = []
      for suggestion in list where byLabel[suggestion.label] == nil {
        byLabel[suggestion.label] = suggestion
        labels.append(suggestion.label)
      }
      // nothing is highlighted until the person moves into the list with the arrows
      index?.pointee = -1
      return labels
    }
  }
}

/// Completion works on the piece between commas, so "long ha" completes to "long hair"
/// as one tag instead of word by word.
@available(macOS 26, *)
final class CompletingTextView: NSTextView {
  weak var coordinator: PromptTextView.Coordinator?
  /// Set once the arrows move through the open list; only then may Return or Tab take an entry.
  private var navigated = false

  /// Whatever takes the field out of the window (SwiftUI dropping it, a folded section) takes its
  /// undo steps out first, while the window and its history can still be reached.
  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow == nil { TextUndo.forget(self) }
    super.viewWillMove(toWindow: newWindow)
  }

  override func complete(_ sender: Any?) {
    navigated = false
    super.complete(sender)
  }

  override var rangeForUserCompletion: NSRange {
    let text = string as NSString
    let caret = selectedRange().location
    guard caret != NSNotFound, caret <= text.length else {
      return NSRange(location: NSNotFound, length: 0)
    }
    let stops = CharacterSet(charactersIn: ",;()\n")
    var start = caret
    while start > 0, let scalar = Unicode.Scalar(text.character(at: start - 1)),
      !stops.contains(scalar)
    {
      start -= 1
    }
    while start < caret, let scalar = Unicode.Scalar(text.character(at: start)),
      CharacterSet.whitespaces.contains(scalar)
    {
      start += 1
    }
    return NSRange(location: start, length: caret - start)
  }

  override func insertCompletion(
    _ word: String, forPartialWordRange charRange: NSRange, movement: Int, isFinal flag: Bool
  ) {
    // No inline preview: previewing overwrites whatever the person is still typing. A
    // non-final call is the list's highlight moving, which is how arrow navigation shows up.
    guard flag else {
      if movement == NSTextMovement.up.rawValue || movement == NSTextMovement.down.rawValue {
        navigated = true
      }
      return
    }
    // Only a real choice inserts: a click on the list itself, or Return/Tab after the arrows
    // picked an entry. The list also closes "final" when the person keeps typing or clicks
    // anywhere else, and taking the entry then swapped their word for someone else's.
    let event = NSApp.currentEvent
    let isClick = event.map { [.leftMouseDown, .leftMouseUp].contains($0.type) } ?? false
    let onList =
      isClick
      && (event?.window.map { other in
        other !== window
          && (String(describing: type(of: other)).contains("Completion") || !other.canBecomeKey)
      } ?? false)
    let byKeys =
      navigated
      && (movement == NSTextMovement.return.rawValue || movement == NSTextMovement.tab.rawValue)
    navigated = false
    guard onList || byKeys else { return }
    guard let suggestion = coordinator?.byLabel[word] else {
      super.insertCompletion(word, forPartialWordRange: charRange, movement: movement, isFinal: flag)
      return
    }
    coordinator?.skipNextTrigger = true
    let insert = suggestion.insert + (suggestion.appendsComma ? ", " : "")
    if shouldChangeText(in: charRange, replacementString: insert) {
      replaceCharacters(in: charRange, with: insert)
      didChangeText()
      setSelectedRange(
        NSRange(location: charRange.location + (insert as NSString).length, length: 0))
    }
  }
}
