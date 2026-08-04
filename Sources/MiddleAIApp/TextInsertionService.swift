import AppKit
import ApplicationServices
import Foundation
import MiddleAICore

struct DictationTarget {
  let application: NSRunningApplication?
  let icon: NSImage?
  let bundleIdentifier: String?
  let applicationName: String?
  let focusedElement: AXUIElement?
}

struct TextInsertionResult {
  enum Method: Equatable { case accessibility, clipboard }
  let formatted: FormattedDictation
  let method: Method
  let verified: Bool
}

@MainActor final class TextInsertionService {
  private struct ClipboardItem {
    let values: [(NSPasteboard.PasteboardType, Data)]
  }

  func captureTarget() -> DictationTarget {
    let app = NSWorkspace.shared.frontmostApplication
    let target = app?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : app
    let icon = target?.bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
    let capturedElement: AXUIElement?
    if let target {
      capturedElement = focusedElement(for: target.processIdentifier)
    } else {
      capturedElement = nil
    }
    return DictationTarget(
      application: target, icon: icon, bundleIdentifier: target?.bundleIdentifier,
      applicationName: target?.localizedName, focusedElement: capturedElement)
  }

  func insert(
    _ text: String, into target: DictationTarget, smartFormatting: Bool,
    formattingApplicationIDs: [String]
  ) async throws -> TextInsertionResult {
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

    if !formatted.didApplyFormatting, let focusedElement = target.focusedElement,
      let direct = try await insertWithAccessibility(
        formatted.plainText, into: focusedElement, application: target.application)
    {
      return TextInsertionResult(formatted: formatted, method: .accessibility, verified: direct)
    }

    return try await insertWithClipboard(formatted, into: target)
  }

  private func insertWithClipboard(
    _ formatted: FormattedDictation, into target: DictationTarget
  ) async throws -> TextInsertionResult {

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
    let verificationSnapshot = target.focusedElement.flatMap(textSnapshot(of:))
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
      let verified = try await verifyClipboardInsertion(
        formatted.plainText, element: target.focusedElement, snapshot: verificationSnapshot,
        timeout: profile.pasteCompletionDelay)
      if !verified, let verificationSnapshot,
        currentText(of: target.focusedElement) == verificationSnapshot.text
      {
        guard postPasteShortcut() else { throw VoiceInputError.couldNotInsertText }
        guard
          try await verifyClipboardInsertion(
            formatted.plainText, element: target.focusedElement, snapshot: verificationSnapshot,
            timeout: profile.pasteCompletionDelay)
        else { throw VoiceInputError.couldNotVerifyTextInsertion }
      } else if !verified, verificationSnapshot != nil {
        throw VoiceInputError.couldNotVerifyTextInsertion
      }
      if pasteboard.changeCount == transcriptChangeCount { restoreClipboard(saved, to: pasteboard) }
      return TextInsertionResult(
        formatted: formatted, method: .clipboard, verified: verified)
    } catch {
      if pasteboard.changeCount == transcriptChangeCount { restoreClipboard(saved, to: pasteboard) }
      throw error
    }
  }

  /// Returns nil when direct AX insertion is unsupported and the clipboard fallback is safe.
  /// Once AX reports success, a failed verification is surfaced instead of pasting a duplicate.
  private func insertWithAccessibility(
    _ text: String, into element: AXUIElement, application: NSRunningApplication?
  ) async throws -> Bool? {
    guard application?.isTerminated != true else {
      throw VoiceInputError.targetApplicationUnavailable
    }
    guard !isSecureTextField(element), let snapshot = textSnapshot(of: element) else { return nil }
    var settable = DarwinBoolean(false)
    guard
      AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
        == .success, settable.boolValue
    else { return nil }
    let status = AXUIElementSetAttributeValue(
      element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
    guard status == .success else { return nil }
    let expected = snapshot.replacingSelection(with: text)
    for _ in 0..<6 {
      if currentText(of: element) == expected { return true }
      try await Task.sleep(for: .milliseconds(35))
    }
    throw VoiceInputError.couldNotVerifyTextInsertion
  }

  private func verifyClipboardInsertion(
    _ insertedText: String, element: AXUIElement?, snapshot: TextSnapshot?, timeout: TimeInterval
  ) async throws -> Bool {
    guard let element, let snapshot else {
      try await Task.sleep(for: .seconds(timeout))
      return false
    }
    let expected = snapshot.replacingSelection(with: insertedText)
    let deadline = Date().addingTimeInterval(max(0.2, timeout))
    repeat {
      if currentText(of: element) == expected { return true }
      try await Task.sleep(for: .milliseconds(50))
    } while Date() < deadline
    return false
  }

  private func focusedElement(for processIdentifier: pid_t) -> AXUIElement? {
    let application = AXUIElementCreateApplication(processIdentifier)
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        application, kAXFocusedUIElementAttribute as CFString, &value) == .success,
      let value, CFGetTypeID(value) == AXUIElementGetTypeID()
    else { return nil }
    return unsafeDowncast(value as AnyObject, to: AXUIElement.self)
  }

  private func currentText(of element: AXUIElement?) -> String? {
    guard let element else { return nil }
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success
    else { return nil }
    return value as? String
  }

  private func textSnapshot(of element: AXUIElement) -> TextSnapshot? {
    guard let text = currentText(of: element) else { return nil }
    var selectionValue: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        element, kAXSelectedTextRangeAttribute as CFString, &selectionValue) == .success,
      let selectionValue, CFGetTypeID(selectionValue) == AXValueGetTypeID()
    else { return nil }
    var range = CFRange()
    guard AXValueGetValue(selectionValue as! AXValue, .cfRange, &range), range.location >= 0,
      range.length >= 0, range.location + range.length <= (text as NSString).length
    else { return nil }
    return TextSnapshot(text: text, selection: range)
  }

  private func isSecureTextField(_ element: AXUIElement) -> Bool {
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &value) == .success
    else { return false }
    return (value as? String) == kAXSecureTextFieldSubrole
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

  private struct TextSnapshot {
    let text: String
    let selection: CFRange

    func replacingSelection(with replacement: String) -> String {
      (text as NSString).replacingCharacters(
        in: NSRange(location: selection.location, length: selection.length), with: replacement)
    }
  }
}

enum VoiceInputError: LocalizedError {
  case accessibilityPermissionMissing
  case inputMonitoringPermissionMissing
  case couldNotInsertText
  case couldNotVerifyTextInsertion
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
    case .couldNotVerifyTextInsertion:
      return "MiddleAI konnte nicht sicher bestätigen, dass der Text eingefügt wurde."
    case .targetApplicationUnavailable:
      return "Die Zielanwendung ist nicht mehr aktiv. Bitte das Textfeld erneut auswählen."
    case .assistantNotConfigured:
      return "Der Antwortanbieter ist in MiddleAI noch nicht eingerichtet."
    case .recordingCancelled: return "Diktat abgebrochen."
    }
  }
}
