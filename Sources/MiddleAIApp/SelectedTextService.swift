import AppKit
@preconcurrency import ApplicationServices
import Foundation

struct SelectedTextContext {
  let application: NSRunningApplication
  let element: AXUIElement
  let text: String
  let selectedRange: CFRange

  var applicationName: String { application.localizedName ?? "Zielanwendung" }
}

enum SelectedTextServiceError: LocalizedError {
  case accessibilityPermissionMissing
  case noCompatibleSelection
  case secureTextField
  case selectionTooLarge
  case targetUnavailable
  case replacementFailed

  var errorDescription: String? {
    switch self {
    case .accessibilityPermissionMissing:
      return "MiddleAI benötigt Bedienungshilfen, um markierten Text zu lesen und zu ersetzen."
    case .noCompatibleSelection:
      return "In der aktiven Anwendung ist kein kompatibler Text markiert."
    case .secureTextField:
      return "In geschützten Eingabefeldern verarbeitet MiddleAI grundsätzlich keinen Text."
    case .selectionTooLarge:
      return "Die Auswahl ist für eine einzelne lokale Textaktion zu groß."
    case .targetUnavailable:
      return "Die Anwendung mit der ursprünglichen Textauswahl ist nicht mehr verfügbar."
    case .replacementFailed:
      return "Der überarbeitete Text konnte nicht sicher eingesetzt werden."
    }
  }
}

/// Reads only the explicitly selected text in the frontmost application. The service deliberately
/// does not inspect surrounding paragraphs, window titles or clipboard content.
@MainActor final class SelectedTextService {
  static let maximumCharacters = 50_000

  func capture() throws -> SelectedTextContext {
    guard AXIsProcessTrusted() else {
      throw SelectedTextServiceError.accessibilityPermissionMissing
    }
    guard let application = NSWorkspace.shared.frontmostApplication,
      application.bundleIdentifier != Bundle.main.bundleIdentifier,
      !application.isTerminated
    else { throw SelectedTextServiceError.noCompatibleSelection }

    let appElement = AXUIElementCreateApplication(application.processIdentifier)
    var focusedValue: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        appElement, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
      let focusedValue, CFGetTypeID(focusedValue) == AXUIElementGetTypeID()
    else { throw SelectedTextServiceError.noCompatibleSelection }
    let element = unsafeDowncast(focusedValue as AnyObject, to: AXUIElement.self)

    var subroleValue: CFTypeRef?
    if AXUIElementCopyAttributeValue(
      element, kAXSubroleAttribute as CFString, &subroleValue) == .success,
      (subroleValue as? String) == kAXSecureTextFieldSubrole
    {
      throw SelectedTextServiceError.secureTextField
    }

    var selectedValue: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        element, kAXSelectedTextAttribute as CFString, &selectedValue) == .success,
      let selectedText = selectedValue as? String,
      !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { throw SelectedTextServiceError.noCompatibleSelection }
    guard selectedText.count <= Self.maximumCharacters else {
      throw SelectedTextServiceError.selectionTooLarge
    }

    var rangeValue: CFTypeRef?
    var range = CFRange()
    guard
      AXUIElementCopyAttributeValue(
        element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
      let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID(),
      AXValueGetValue(rangeValue as! AXValue, .cfRange, &range), range.location >= 0,
      range.length > 0
    else { throw SelectedTextServiceError.noCompatibleSelection }

    return SelectedTextContext(
      application: application, element: element, text: selectedText, selectedRange: range)
  }

  func replace(_ context: SelectedTextContext, with replacement: String) async throws {
    guard !context.application.isTerminated else {
      throw SelectedTextServiceError.targetUnavailable
    }
    let clean = String(replacement.prefix(Self.maximumCharacters))
    guard !clean.isEmpty else { throw SelectedTextServiceError.replacementFailed }
    context.application.activate()
    for _ in 0..<12 where !context.application.isActive {
      try await Task.sleep(for: .milliseconds(50))
    }
    guard context.application.isActive else { throw SelectedTextServiceError.targetUnavailable }

    var settable = DarwinBoolean(false)
    guard
      AXUIElementIsAttributeSettable(
        context.element, kAXSelectedTextAttribute as CFString, &settable) == .success,
      settable.boolValue,
      AXUIElementSetAttributeValue(
        context.element, kAXSelectedTextAttribute as CFString, clean as CFTypeRef) == .success
    else { throw SelectedTextServiceError.replacementFailed }
  }
}
