import AppKit
import ApplicationServices
import Foundation
import MiddleAICore

struct DictationTarget {
  let application: NSRunningApplication?
  let icon: NSImage?
  let bundleIdentifier: String?
  let applicationName: String?
}

@MainActor final class TextInsertionService {
  private struct ClipboardItem {
    let values: [(NSPasteboard.PasteboardType, Data)]
  }

  func captureTarget() -> DictationTarget {
    let app = NSWorkspace.shared.frontmostApplication
    let target = app?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : app
    let icon = target?.bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
    return DictationTarget(
      application: target, icon: icon, bundleIdentifier: target?.bundleIdentifier,
      applicationName: target?.localizedName)
  }

  func insert(
    _ text: String, into target: DictationTarget, smartFormatting: Bool,
    formattingApplicationIDs: [String]
  ) async throws -> FormattedDictation {
    guard AXIsProcessTrusted() else {
      throw VoiceInputError.accessibilityPermissionMissing
    }
    let formattingEnabledForTarget =
      target.bundleIdentifier.map { targetID in
        formattingApplicationIDs.contains { $0.caseInsensitiveCompare(targetID) == .orderedSame }
      } ?? false
    let formatted =
      smartFormatting && formattingEnabledForTarget
      ? DictationFormatter.format(text)
      : FormattedDictation(plainText: text, html: "", didApplyFormatting: false)

    let pasteboard = NSPasteboard.general
    let saved = saveClipboard(pasteboard)
    pasteboard.clearContents()
    let item = NSPasteboardItem()
    guard item.setString(formatted.plainText, forType: .string) else {
      throw VoiceInputError.couldNotInsertText
    }
    if formatted.didApplyFormatting {
      item.setString(formatted.html, forType: .html)
      if let rtf = rtfData(from: formatted.html) { item.setData(rtf, forType: .rtf) }
    }
    guard pasteboard.writeObjects([item]) else { throw VoiceInputError.couldNotInsertText }
    let transcriptChangeCount = pasteboard.changeCount
    let profile = InsertionProfile(bundleIdentifier: target.bundleIdentifier)
    do {
      if let application = target.application {
        guard !application.isTerminated else { throw VoiceInputError.targetApplicationUnavailable }
        application.activate()
        for _ in 0..<12 where !application.isActive {
          try await Task.sleep(for: .milliseconds(50))
        }
        guard application.isActive else { throw VoiceInputError.targetApplicationUnavailable }
      }
      try await Task.sleep(for: .seconds(profile.activationDelay))
      guard postPasteShortcut() else { throw VoiceInputError.couldNotInsertText }
      try await Task.sleep(for: .seconds(profile.pasteCompletionDelay))
    } catch {
      if pasteboard.changeCount == transcriptChangeCount { restoreClipboard(saved, to: pasteboard) }
      throw error
    }
    if pasteboard.changeCount == transcriptChangeCount { restoreClipboard(saved, to: pasteboard) }
    return formatted
  }

  private func postPasteShortcut() -> Bool {
    guard let source = CGEventSource(stateID: .combinedSessionState),
      let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
      let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
    else { return false }
    down.flags = .maskCommand
    up.flags = .maskCommand
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
    return true
  }

  private func rtfData(from html: String) -> Data? {
    guard let data = html.data(using: .utf8),
      let attributed = try? NSAttributedString(
        data: data,
        options: [
          .documentType: NSAttributedString.DocumentType.html,
          .characterEncoding: String.Encoding.utf8.rawValue,
        ],
        documentAttributes: nil)
    else { return nil }
    return try? attributed.data(
      from: NSRange(location: 0, length: attributed.length),
      documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
  }

  private func saveClipboard(_ pasteboard: NSPasteboard) -> [ClipboardItem] {
    (pasteboard.pasteboardItems ?? []).map { item in
      let values = item.types.compactMap { type in
        item.data(forType: type).map { (type, $0) }
      }
      return ClipboardItem(values: values)
    }
  }

  private func restoreClipboard(_ items: [ClipboardItem], to pasteboard: NSPasteboard) {
    pasteboard.clearContents()
    let restored = items.map { saved -> NSPasteboardItem in
      let item = NSPasteboardItem()
      for (type, data) in saved.values { item.setData(data, forType: type) }
      return item
    }
    if !restored.isEmpty { pasteboard.writeObjects(restored) }
  }

  private struct InsertionProfile {
    let activationDelay: TimeInterval
    let pasteCompletionDelay: TimeInterval

    init(bundleIdentifier: String?) {
      switch bundleIdentifier?.lowercased() {
      case "com.microsoft.word", "com.microsoft.powerpoint", "com.microsoft.outlook":
        activationDelay = 0.18
        pasteCompletionDelay = 0.65
      case "ch.protonmail.desktop":
        activationDelay = 0.15
        pasteCompletionDelay = 0.45
      default:
        activationDelay = 0.12
        pasteCompletionDelay = 0.35
      }
    }
  }
}

enum VoiceInputError: LocalizedError {
  case accessibilityPermissionMissing
  case inputMonitoringPermissionMissing
  case couldNotInsertText
  case targetApplicationUnavailable
  case assistantNotConfigured
  case recordingCancelled

  var errorDescription: String? {
    switch self {
    case .accessibilityPermissionMissing:
      return "Bitte MiddleAI unter Datenschutz & Sicherheit > Bedienungshilfen erlauben."
    case .inputMonitoringPermissionMissing:
      return "Bitte MiddleAI unter Datenschutz & Sicherheit > Eingabeüberwachung erlauben."
    case .couldNotInsertText: return "Der erkannte Text konnte nicht eingefügt werden."
    case .targetApplicationUnavailable:
      return "Die Zielanwendung ist nicht mehr aktiv. Bitte das Textfeld erneut auswählen."
    case .assistantNotConfigured: return "OpenWebUI ist in MiddleAI noch nicht eingerichtet."
    case .recordingCancelled: return "Diktat abgebrochen."
    }
  }
}
