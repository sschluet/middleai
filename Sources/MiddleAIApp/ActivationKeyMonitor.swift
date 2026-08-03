import AppKit
import Foundation

enum ActivationKeyChoice: String, CaseIterable, Identifiable {
  case leftOption = "left_option"
  case rightOption = "right_option"
  case leftControl = "left_control"
  case rightControl = "right_control"
  case leftCommand = "left_command"
  case rightCommand = "right_command"
  case leftShift = "left_shift"
  case rightShift = "right_shift"

  var id: String { rawValue }

  var keyCode: UInt16 {
    switch self {
    case .leftOption: return 58
    case .rightOption: return 61
    case .leftControl: return 59
    case .rightControl: return 62
    case .leftCommand: return 55
    case .rightCommand: return 54
    case .leftShift: return 56
    case .rightShift: return 60
    }
  }

  var label: String {
    switch self {
    case .leftOption: return "Linke Optionstaste"
    case .rightOption: return "Rechte Optionstaste"
    case .leftControl: return "Linke Control-Taste"
    case .rightControl: return "Rechte Control-Taste"
    case .leftCommand: return "Linke Command-Taste"
    case .rightCommand: return "Rechte Command-Taste"
    case .leftShift: return "Linke Umschalttaste"
    case .rightShift: return "Rechte Umschalttaste"
    }
  }

  var compactLabel: String {
    switch self {
    case .leftOption: return "⌥ links"
    case .rightOption: return "⌥ rechts"
    case .leftControl: return "⌃ links"
    case .rightControl: return "⌃ rechts"
    case .leftCommand: return "⌘ links"
    case .rightCommand: return "⌘ rechts"
    case .leftShift: return "⇧ links"
    case .rightShift: return "⇧ rechts"
    }
  }

  var modifierFlag: NSEvent.ModifierFlags {
    switch self {
    case .leftOption, .rightOption: return .option
    case .leftControl, .rightControl: return .control
    case .leftCommand, .rightCommand: return .command
    case .leftShift, .rightShift: return .shift
    }
  }
}

@MainActor final class ActivationKeyMonitor {
  private let keys: () -> (dictation: ActivationKeyChoice, assistant: ActivationKeyChoice)
  private let onPressed: (VoiceMode) -> Void
  private let onReleased: (VoiceMode) -> Void
  private let onCancelled: () -> Void
  private var globalFlagsMonitor: Any?
  private var localFlagsMonitor: Any?
  private var globalKeyMonitor: Any?
  private var localKeyMonitor: Any?
  private var pressed: Set<UInt16> = []

  init(
    keys: @escaping () -> (dictation: ActivationKeyChoice, assistant: ActivationKeyChoice),
    onPressed: @escaping (VoiceMode) -> Void,
    onReleased: @escaping (VoiceMode) -> Void,
    onCancelled: @escaping () -> Void
  ) {
    self.keys = keys
    self.onPressed = onPressed
    self.onReleased = onReleased
    self.onCancelled = onCancelled
  }

  func start() {
    stop()
    globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) {
      [weak self] event in
      Task { @MainActor in self?.handleFlags(event) }
    }
    localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) {
      [weak self] event in
      self?.handleFlags(event)
      return event
    }
    globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [
      .keyDown, .leftMouseDown, .rightMouseDown,
    ]) {
      [weak self] _ in
      Task { @MainActor in self?.cancelIfActivationKeyIsHeld() }
    }
    localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [
      .keyDown, .leftMouseDown, .rightMouseDown,
    ]) {
      [weak self] event in
      self?.cancelIfActivationKeyIsHeld()
      return event
    }
  }

  func stop() {
    for monitor in [globalFlagsMonitor, localFlagsMonitor, globalKeyMonitor, localKeyMonitor] {
      if let monitor { NSEvent.removeMonitor(monitor) }
    }
    globalFlagsMonitor = nil
    localFlagsMonitor = nil
    globalKeyMonitor = nil
    localKeyMonitor = nil
    pressed.removeAll()
  }

  private func handleFlags(_ event: NSEvent) {
    let configured = keys()
    let mode: VoiceMode
    if event.keyCode == configured.dictation.keyCode {
      mode = .dictation
    } else if event.keyCode == configured.assistant.keyCode {
      mode = .assistant
    } else {
      return
    }
    let keyCode = event.keyCode
    // `CGEventSource.keyState` can incorrectly report modifier keys as released when
    // Input Monitoring was re-authorized after an app update. The flagsChanged event
    // already contains the authoritative modifier state and still distinguishes the
    // physical side through its key code.
    let selectedKey = mode == .dictation ? configured.dictation : configured.assistant
    let isDown = event.modifierFlags.contains(selectedKey.modifierFlag)
    if isDown, !pressed.contains(keyCode) {
      pressed.insert(keyCode)
      onPressed(mode)
    } else if !isDown, pressed.remove(keyCode) != nil {
      onReleased(mode)
    }
  }

  private func cancelIfActivationKeyIsHeld() {
    guard !pressed.isEmpty else { return }
    pressed.removeAll()
    onCancelled()
  }
}
