import AppKit

/// Native macOS Services entry point for text selected in another application. The service only
/// receives plain text and never returns an immediate replacement: MiddleAI keeps its existing
/// preview and explicit-apply boundary before writing back through Accessibility.
@MainActor final class MiddleAITextServiceProvider: NSObject {
  static let shared = MiddleAITextServiceProvider()

  private var handler: ((String) -> Void)?

  func configure(handler: @escaping (String) -> Void) {
    self.handler = handler
    NSApp.servicesProvider = self
    NSUpdateDynamicServices()
  }

  @objc func editSelectedText(
    _ pasteboard: NSPasteboard, userData: String?,
    error: AutoreleasingUnsafeMutablePointer<NSString?>
  ) {
    guard let text = pasteboard.string(forType: .string),
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      error.pointee =
        "MiddleAI hat vom Kontextmenü keinen markierten Text erhalten."
        as NSString
      return
    }
    guard text.count <= SelectedTextService.maximumCharacters else {
      error.pointee =
        "Die markierte Auswahl ist für eine einzelne MiddleAI-Aktion zu groß."
        as NSString
      return
    }
    guard let handler else {
      error.pointee = "MiddleAI ist noch nicht bereit, markierten Text zu verarbeiten." as NSString
      return
    }
    handler(text)
  }
}
