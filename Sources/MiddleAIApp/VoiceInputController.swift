import AppKit
import AVFoundation
import ApplicationServices
import Foundation
import MiddleAICore
import OSLog

struct DictationTarget {
  let application: NSRunningApplication?
  let icon: NSImage?
  let supportedApplication: SupportedDictationApplication?
}

enum SupportedDictationApplication: String, CaseIterable {
  case word
  case powerPoint
  case outlook
  case protonMail

  init?(bundleIdentifier: String?) {
    switch bundleIdentifier?.lowercased() {
    case "com.microsoft.word": self = .word
    case "com.microsoft.powerpoint": self = .powerPoint
    case "com.microsoft.outlook": self = .outlook
    case "ch.protonmail.desktop": self = .protonMail
    default: return nil
    }
  }

  var name: String {
    switch self {
    case .word: return "Microsoft Word"
    case .powerPoint: return "Microsoft PowerPoint"
    case .outlook: return "Microsoft Outlook"
    case .protonMail: return "Proton Mail"
    }
  }
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
      application: target, icon: icon,
      supportedApplication: SupportedDictationApplication(bundleIdentifier: target?.bundleIdentifier))
  }

  func insert(
    _ text: String, into target: DictationTarget, smartFormatting: Bool
  ) throws -> FormattedDictation {
    guard AXIsProcessTrusted() else {
      throw VoiceInputError.accessibilityPermissionMissing
    }
    let formatted = smartFormatting && target.supportedApplication != nil
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
    target.application?.activate()

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
      let source = CGEventSource(stateID: .combinedSessionState)
      let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
      let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
      down?.flags = .maskCommand
      up?.flags = .maskCommand
      down?.post(tap: .cghidEventTap)
      up?.post(tap: .cghidEventTap)
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
      guard pasteboard.changeCount == transcriptChangeCount else { return }
      self.restoreClipboard(saved, to: pasteboard)
    }
    return formatted
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
}

enum VoiceInputError: LocalizedError {
  case accessibilityPermissionMissing
  case inputMonitoringPermissionMissing
  case couldNotInsertText
  case assistantNotConfigured
  case recordingCancelled

  var errorDescription: String? {
    switch self {
    case .accessibilityPermissionMissing:
      return "Bitte MiddleAI unter Datenschutz & Sicherheit > Bedienungshilfen erlauben."
    case .inputMonitoringPermissionMissing:
      return "Bitte MiddleAI unter Datenschutz & Sicherheit > Eingabeüberwachung erlauben."
    case .couldNotInsertText: return "Der erkannte Text konnte nicht eingefügt werden."
    case .assistantNotConfigured: return "OpenWebUI ist in MiddleAI noch nicht eingerichtet."
    case .recordingCancelled: return "Diktat abgebrochen."
    }
  }
}

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
    globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) {
      [weak self] _ in
      Task { @MainActor in self?.cancelIfActivationKeyIsHeld() }
    }
    localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) {
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

@MainActor final class VoiceInputController {
  typealias EngineProvider = @MainActor () -> MiddleAIEngine?
  typealias ConfigProvider = @MainActor () -> AppConfig

  private let recorder = MicrophoneRecorder()
  private let transcriber = ParakeetTranscriber()
  private let polisher = DictationPolisher()
  private let insertion = TextInsertionService()
  private let overlay = VoiceNotchPresenter()
  private let engineProvider: EngineProvider
  private let configProvider: ConfigProvider
  private let onStatus: (String) -> Void
  private let onStarted: () -> Void
  private let onResult: (InputResult) -> Void
  private let onError: (String) -> Void
  private let onDismissed: () -> Void
  private lazy var keyMonitor = ActivationKeyMonitor(
    keys: { [weak self] in self?.activationKeys ?? (.leftOption, .rightOption) },
    onPressed: { [weak self] in self?.press($0) },
    onReleased: { [weak self] in self?.release($0) },
    onCancelled: { [weak self] in self?.cancel() })
  private var activeMode: VoiceMode?
  private var latchedMode: VoiceMode?
  private var ignoreReleaseForMode: VoiceMode?
  private var recordingStartedAt: Date?
  private var dictationTarget: DictationTarget?
  private var processingTask: Task<Void, Never>?
  private var assistantRequestActive = false
  private var microphoneAuthorized = false
  private let logger = Logger(subsystem: "de.middleai.app", category: "voice")

  init(
    engineProvider: @escaping EngineProvider,
    configProvider: @escaping ConfigProvider,
    onStatus: @escaping (String) -> Void,
    onStarted: @escaping () -> Void,
    onResult: @escaping (InputResult) -> Void,
    onError: @escaping (String) -> Void,
    onDismissed: @escaping () -> Void
  ) {
    self.engineProvider = engineProvider
    self.configProvider = configProvider
    self.onStatus = onStatus
    self.onStarted = onStarted
    self.onResult = onResult
    self.onError = onError
    self.onDismissed = onDismissed
  }

  func prepare() {
    requestPermissions()
    logger.notice("accessibility_trusted=\(AXIsProcessTrusted(), privacy: .public)")
    keyMonitor.start()
    onStatus("Sprachmodell wird vorbereitet")
    Task { [weak self] in
      guard let self else { return }
      do {
        try await self.transcriber.prepare()
        await MainActor.run { self.onStatus(self.readyStatus) }
      } catch {
        await MainActor.run { self.onStatus("Sprachmodell wird beim ersten Diktat geladen") }
      }
    }
  }

  func reloadActivationKeys() {
    keyMonitor.start()
    onStatus(readyStatus)
  }

  private var activationKeys: (dictation: ActivationKeyChoice, assistant: ActivationKeyChoice) {
    let configured = configProvider().hotkeys
    return (
      ActivationKeyChoice(rawValue: configured.dictation) ?? .leftOption,
      ActivationKeyChoice(rawValue: configured.assistant) ?? .rightOption)
  }

  private var readyStatus: String {
    let keys = activationKeys
    return "Voice bereit: \(keys.dictation.compactLabel) / \(keys.assistant.compactLabel)"
  }

  private func requestPermissions() {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      microphoneAuthorized = true
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
        Task { @MainActor in self?.microphoneAuthorized = granted }
      }
    default:
      microphoneAuthorized = false
    }
    let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(prompt)
  }

  private func press(_ mode: VoiceMode) {
    if activeMode == mode, latchedMode == mode {
      latchedMode = nil
      ignoreReleaseForMode = mode
      finishRecording(mode)
      return
    }
    if mode == .assistant,
      assistantRequestActive || engineProvider()?.ttsQueue.isSpeaking == true
    {
      assistantRequestActive = false
      processingTask?.cancel()
      processingTask = nil
      engineProvider()?.interrupt()
      overlay.hide()
      ignoreReleaseForMode = .assistant
      onDismissed()
      onStatus("Antwort und Sprachausgabe abgebrochen")
      return
    }
    guard activeMode == nil else {
      cancel()
      return
    }
    processingTask?.cancel()
    engineProvider()?.ttsQueue.stop()
    guard microphoneAuthorized else {
      requestPermissions()
      fail(VoiceCaptureError.microphonePermissionDenied)
      return
    }
    activeMode = mode
    recordingStartedAt = Date()
    dictationTarget = mode == .dictation ? insertion.captureTarget() : nil
    overlay.show(mode: mode, targetIcon: dictationTarget?.icon)
    do {
      try recorder.start { [weak self] level in
        Task { @MainActor in self?.overlay.setLevel(level) }
      }
      onStatus(mode == .dictation ? "Diktat läuft" : "MiddleAI hört zu")
    } catch {
      activeMode = nil
      recordingStartedAt = nil
      fail(error)
    }
  }

  private func release(_ mode: VoiceMode) {
    if ignoreReleaseForMode == mode {
      ignoreReleaseForMode = nil
      return
    }
    guard activeMode == mode else { return }
    if let recordingStartedAt, Date().timeIntervalSince(recordingStartedAt) < 0.32 {
      latchedMode = mode
      onStatus(
        mode == .dictation
          ? "Diktat aktiv – \(activationKeys.dictation.label) beendet"
          : "MiddleAI hört zu – \(activationKeys.assistant.label) beendet")
      return
    }
    finishRecording(mode)
  }

  private func finishRecording(_ mode: VoiceMode) {
    guard activeMode == mode else { return }
    activeMode = nil
    latchedMode = nil
    recordingStartedAt = nil
    let audio = recorder.stop()
    let target = dictationTarget
    dictationTarget = nil
    guard audio.duration >= 0.25, audio.samples.count >= 1_600 else {
      dismissSilently()
      return
    }
    overlay.update(phase: .transcribing, detail: "Parakeet TDT v3 verarbeitet die Aufnahme lokal")
    processingTask = Task { [weak self] in
      guard let self else { return }
      do {
        let text = try await self.transcriber.transcribe(audio)
        try Task.checkCancellation()
        guard Self.isMeaningfulTranscript(text) else {
          await MainActor.run { self.dismissSilently() }
          return
        }
        if mode == .dictation {
          let polishingEnabled = await MainActor.run {
            self.configProvider().dictation.polishWithLocalAI
          }
          if polishingEnabled {
            await MainActor.run {
              self.overlay.update(
                phase: .polishing,
                detail: "Apple Intelligence glättet Füllwörter und Versprecher lokal")
              self.onStatus("Diktat wird lokal geglättet")
            }
          }
          let finalText = await self.polisher.polish(text, enabled: polishingEnabled)
          try Task.checkCancellation()
          await MainActor.run { self.finishDictation(finalText, target: target) }
        } else {
          await MainActor.run { self.runAssistant(text) }
        }
      } catch is CancellationError {
        await MainActor.run { self.overlay.hide() }
      } catch let error as VoiceCaptureError {
        await MainActor.run {
          switch error {
          case .recordingTooShort, .emptyTranscription: self.dismissSilently()
          default: self.fail(error)
          }
        }
      } catch {
        await MainActor.run { self.fail(error) }
      }
    }
  }

  private func finishDictation(_ text: String, target: DictationTarget?) {
    do {
      let destination = target ?? insertion.captureTarget()
      let smartFormatting = configProvider().dictation.smartFormatting
      let inserted = try insertion.insert(
        text, into: destination, smartFormatting: smartFormatting)
      overlay.update(phase: .result, detail: inserted.plainText)
      overlay.hide(after: 1.4)
      if inserted.didApplyFormatting, let app = destination.supportedApplication {
        onStatus("Diktat für \(app.name) formatiert und eingefügt")
      } else {
        onStatus("Diktat eingefügt")
      }
    } catch {
      fail(error)
    }
  }

  private func runAssistant(_ text: String) {
    guard let engine = engineProvider() else {
      fail(VoiceInputError.assistantNotConfigured)
      return
    }
    overlay.update(phase: .thinking, detail: text)
    assistantRequestActive = true
    onStarted()
    onStatus("OpenWebUI verarbeitet die Sprachanfrage")
    processingTask = Task { [weak self] in
      guard let self else { return }
      do {
        try await engine.client.authenticate()
        let result = try await engine.handle(text: text, source: "voice-assistant")
        try Task.checkCancellation()
        await MainActor.run {
          self.assistantRequestActive = false
          self.processingTask = nil
          self.onResult(result)
          let answer = result.displayText
          if case .local = result { engine.ttsQueue.enqueue(answer) }
          if case .clarification = result { /* already queued by the engine */ }
          self.overlay.update(phase: .result, detail: answer)
          self.overlay.hide(after: 4.5)
          self.onStatus(String(answer.prefix(60)))
        }
      } catch is CancellationError {
        await MainActor.run {
          self.assistantRequestActive = false
          self.processingTask = nil
          self.overlay.hide()
        }
      } catch {
        await MainActor.run {
          self.assistantRequestActive = false
          self.processingTask = nil
          self.fail(error)
        }
      }
    }
  }

  private func cancel() {
    guard activeMode != nil else { return }
    activeMode = nil
    latchedMode = nil
    ignoreReleaseForMode = nil
    recordingStartedAt = nil
    dictationTarget = nil
    recorder.cancel()
    overlay.hide()
    onStatus("Voice abgebrochen")
  }

  private func dismissSilently() {
    overlay.hide()
    onDismissed()
    onStatus(readyStatus)
  }

  private nonisolated static func isMeaningfulTranscript(_ text: String) -> Bool {
    let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }
    guard !words.isEmpty else { return false }
    let fillerOnly: Set<String> = ["äh", "ähm", "hm", "mhm"]
    return words.contains { !fillerOnly.contains(String($0)) }
  }

  private func fail(_ error: Error) {
    let message = error.localizedDescription
    logger.error(
      "voice_failed type=\(String(describing: type(of: error)), privacy: .public) reason=\(message, privacy: .private(mask: .hash))"
    )
    overlay.update(phase: .error, detail: message)
    overlay.hide(after: 3.5)
    onStatus("Voice-Fehler")
    onError(message)
  }
}

private extension InputResult {
  var displayText: String {
    switch self {
    case .response(let text, _), .local(let text), .clarification(let text): return text
    }
  }
}
