import AVFoundation
import AppKit
@preconcurrency import ApplicationServices
import Foundation
import MiddleAICore
import OSLog

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
        try await self.transcriber.prepare(settings: self.configProvider().stt)
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

  func reloadSTTSettings() {
    onStatus("STT-Modell wird mit den neuen Einstellungen geladen")
    Task { [weak self] in
      guard let self else { return }
      do {
        try await self.transcriber.prepare(settings: self.configProvider().stt)
        await MainActor.run { self.onStatus(self.readyStatus) }
      } catch {
        await MainActor.run { self.fail(error) }
      }
    }
  }

  private var activationKeys: (dictation: ActivationKeyChoice, assistant: ActivationKeyChoice) {
    let configured = configProvider().hotkeys
    return (
      ActivationKeyChoice(rawValue: configured.dictation) ?? .leftOption,
      ActivationKeyChoice(rawValue: configured.assistant) ?? .rightOption
    )
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
    // The C SDK exposes kAXTrustedCheckOptionPrompt as mutable global state, which is not
    // concurrency-safe under Swift 6. Its documented dictionary key is stable.
    let prompt = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
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
        let text = try await self.transcriber.transcribe(
          audio, settings: self.configProvider().stt)
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
          await self.finishDictation(finalText, target: target)
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

  private func finishDictation(_ text: String, target: DictationTarget?) async {
    do {
      let destination = target ?? insertion.captureTarget()
      let dictationConfig = configProvider().dictation
      let inserted = try await insertion.insert(
        text, into: destination, smartFormatting: dictationConfig.smartFormatting,
        formattingApplicationIDs: dictationConfig.formattingApplications)
      overlay.update(phase: .result, detail: inserted.plainText)
      overlay.hide(after: 1.4)
      if inserted.didApplyFormatting, let appName = destination.applicationName {
        onStatus("Diktat für \(appName) formatiert und eingefügt")
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

extension InputResult {
  fileprivate var displayText: String {
    switch self {
    case .response(let text, _), .local(let text), .clarification(let text): return text
    }
  }
}
