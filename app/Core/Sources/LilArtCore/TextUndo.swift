import AppKit

/// The window keeps one undo history for every text field in it, and each typing step in it is
/// aimed at the field's text storage without the history holding on to it. A field that goes
/// away (the English side replacing the Russian one, a folded section) while its steps are still
/// in that history leaves them pointing at an object that no longer exists, and the next ⌘Z
/// calls it and crashes the app. So a field takes its own steps out when it leaves.
enum TextUndo {
  @MainActor
  static func forget(_ view: NSTextView) {
    guard let storage = view.textStorage else { return }
    view.undoManager?.removeAllActions(withTarget: storage)
  }
}
