import AppKit
@preconcurrency import ApplicationServices
import Foundation

struct SelectedTextContext {
  let application: NSRunningApplication
  let element: AXUIElement?
  let text: String
  let selectedRange: CFRange?

  var applicationName: String { application.localizedName ?? "Zielanwendung" }
  var canReplace: Bool { element != nil && selectedRange != nil }
}

enum SelectedTextServiceError: LocalizedError {
  case accessibilityPermissionMissing
  case noCompatibleSelection
  case secureTextField
  case selectionTooLarge
  case targetUnavailable
  case readOnlySelection
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
    case .readOnlySelection:
      return "Diese Auswahl ist nur lesbar. Du kannst den Vorschlag stattdessen kopieren."
    case .replacementFailed:
      return "Der überarbeitete Text konnte nicht sicher eingesetzt werden."
    }
  }
}

/// Reads only the explicitly selected text in one application. The service deliberately does not
/// inspect surrounding paragraphs, window titles or clipboard content.
@MainActor final class SelectedTextService {
  static let maximumCharacters = 50_000

  func capture(application requestedApplication: NSRunningApplication? = nil) throws
    -> SelectedTextContext
  {
    guard AXIsProcessTrusted() else {
      throw SelectedTextServiceError.accessibilityPermissionMissing
    }
    guard let application = requestedApplication ?? NSWorkspace.shared.frontmostApplication,
      application.bundleIdentifier != Bundle.main.bundleIdentifier,
      application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
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

  /// Services can expose selected text from read-only browser content even when Accessibility does
  /// not expose a writable text element. In that case the pasteboard payload is still accepted as
  /// the explicit user selection, but no target is retained for replacement.
  func captureServiceSelection(
    _ serviceText: String, application requestedApplication: NSRunningApplication?
  ) throws -> SelectedTextContext {
    let text = serviceText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { throw SelectedTextServiceError.noCompatibleSelection }
    guard text.count <= Self.maximumCharacters else {
      throw SelectedTextServiceError.selectionTooLarge
    }
    guard let application = requestedApplication,
      application.bundleIdentifier != Bundle.main.bundleIdentifier,
      application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
      !application.isTerminated
    else { throw SelectedTextServiceError.targetUnavailable }

    do {
      let captured = try capture(application: application)
      if Self.normalized(captured.text) == Self.normalized(serviceText) { return captured }
    } catch SelectedTextServiceError.secureTextField {
      throw SelectedTextServiceError.secureTextField
    } catch {
      // A read-only selection from the Services pasteboard is intentionally supported below.
    }
    return SelectedTextContext(
      application: application, element: nil, text: serviceText, selectedRange: nil)
  }

  func replace(_ context: SelectedTextContext, with replacement: String) async throws {
    guard !context.application.isTerminated else {
      throw SelectedTextServiceError.targetUnavailable
    }
    let clean = String(replacement.prefix(Self.maximumCharacters))
    guard !clean.isEmpty else { throw SelectedTextServiceError.replacementFailed }
    guard let element = context.element else { throw SelectedTextServiceError.readOnlySelection }
    context.application.activate()
    for _ in 0..<12 where !context.application.isActive {
      try await Task.sleep(for: .milliseconds(50))
    }
    guard context.application.isActive else { throw SelectedTextServiceError.targetUnavailable }

    var settable = DarwinBoolean(false)
    guard
      AXUIElementIsAttributeSettable(
        element, kAXSelectedTextAttribute as CFString, &settable) == .success,
      settable.boolValue,
      AXUIElementSetAttributeValue(
        element, kAXSelectedTextAttribute as CFString, clean as CFTypeRef) == .success
    else { throw SelectedTextServiceError.replacementFailed }
  }

  private static func normalized(_ text: String) -> String {
    text.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
  }
}
