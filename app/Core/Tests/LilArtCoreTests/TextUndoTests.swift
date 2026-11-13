import AppKit
import Testing
@testable import LilArtCore

/// Real text views in a real (never shown) window: the history of ⌘Z is the window's, one for
/// every field in it.
@MainActor @Suite(.serialized, .enabled(if: !NSScreen.screens.isEmpty)) struct TextUndoTests {
  private func window() -> NSWindow {
    _ = NSApplication.shared
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered,
      defer: true)
    window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
    return window
  }

  /// A field in the window with one typed word in it. The run loop is given a moment, as after a
  /// key press: that is when the window's undo history closes the group of steps.
  private func typedField(in window: NSWindow, _ word: String) -> NSTextView {
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
    let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
    text.allowsUndo = true
    text.isRichText = false
    scroll.documentView = text
    window.contentView?.addSubview(scroll)
    window.makeFirstResponder(text)
    text.insertText(word, replacementRange: NSRange(location: 0, length: 0))
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    return text
  }

  @Test func typingLeavesStepsInTheWindowsSharedHistory() {
    let w = window()
    _ = typedField(in: w, "hello")
    #expect(w.undoManager?.canUndo == true)
  }

  @Test func aFieldThatLeavesTakesItsStepsWithItAndNothingMore() {
    let w = window()
    let first = typedField(in: w, "one")
    let second = typedField(in: w, "two")
    TextUndo.forget(first)
    #expect(w.undoManager?.canUndo == true)  // the other field's step is still there
    TextUndo.forget(second)
    #expect(w.undoManager?.canUndo == false)
  }

  @Test func aFieldNotInAnyWindowHasNothingToForget() {
    let lonely = NSTextView(frame: .zero)
    TextUndo.forget(lonely)  // must simply do nothing
  }
}
