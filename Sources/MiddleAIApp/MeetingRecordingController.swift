import AppKit
import Foundation
import MiddleAICore

@MainActor final class MeetingRecordingController: ObservableObject {
  @Published private(set) var isRecording = false
  @Published private(set) var isProcessing = false
  @Published private(set) var level: Float = 0
  @Published private(set) var status = "Keine Besprechungsaufnahme aktiv"
  @Published private(set) var lastSession: MeetingSession?
  @Published private(set) var lastMarkdownURL: URL?

  private let recorder = MicrophoneRecorder()
  private let transcriber = ParakeetTranscriber()
  private let coordinator = MeetingSessionCoordinator()
  private var startedAt: Date?
  private var title = "Besprechung"

  func start(title: String?, settings: AppConfig.STT) async throws {
    guard !isRecording, !isProcessing else { throw MeetingSessionError.alreadyRecording }
    let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    self.title = cleanTitle.isEmpty ? "Besprechung" : String(cleanTitle.prefix(120))
    _ = try await coordinator.start(title: self.title)
    do {
      try recorder.start(
        deviceUID: settings.inputDeviceUID,
        maximumDuration: TimeInterval(settings.maximumRecordingSeconds),
        automaticSilenceStop: false,
        onLevel: { [weak self] value in
          Task { @MainActor in self?.level = value }
        },
        onAutomaticStop: { [weak self] _ in
          Task { @MainActor in self?.status = "Maximale Dauer erreicht · bitte Aufnahme beenden" }
        })
      startedAt = Date()
      isRecording = true
      status = "Besprechung wird lokal über das ausgewählte Mikrofon aufgenommen"
    } catch {
      Task { await coordinator.cancel() }
      throw error
    }
  }

  func stop(settings: AppConfig.STT) {
    guard isRecording else { return }
    isRecording = false
    isProcessing = true
    level = 0
    status = "Aufnahme wird lokal transkribiert und zusammengefasst"
    let audio = recorder.stop()
    startedAt = nil
    let selectedSettings = settings
    Task { [weak self] in
      guard let self else { return }
      do {
        guard audio.duration >= 0.25, audio.peakLevel >= 0.01 else {
          await self.coordinator.cancel()
          throw VoiceCaptureError.noAudioSignal(
            "Die Besprechungsaufnahme enthielt kein ausreichendes Mikrofonsignal.")
        }
        let text = try await InferenceScheduler.shared.run(
          workload: .speechRecognition, priority: .userInitiated
        ) {
          try await self.transcriber.transcribe(audio, settings: selectedSettings)
        }
        try await self.coordinator.append(
          text: text, startTime: 0, endTime: audio.duration, confidence: nil)
        let session = try await self.coordinator.stop(
          summarizer: ExtractiveMeetingSummarizer(), at: Date())
        let directory = ConfigLoader.defaultDirectory.appendingPathComponent(
          "meetings", isDirectory: true)
        _ = try await MeetingArchiveStore(directory: directory).save(session)
        let markdown = try MeetingExporter().export(session, format: .markdown, to: directory)
        await MainActor.run {
          self.lastSession = session
          self.lastMarkdownURL = markdown
          self.isProcessing = false
          self.status =
            "Besprechung lokal verarbeitet · \(session.segments.count) Transkriptabschnitt(e)"
        }
      } catch {
        await self.coordinator.cancel()
        await MainActor.run {
          self.isProcessing = false
          self.status = error.localizedDescription
        }
      }
    }
  }

  func cancel() {
    recorder.cancel()
    startedAt = nil
    isRecording = false
    isProcessing = false
    level = 0
    status = "Besprechungsaufnahme verworfen"
    Task { await coordinator.cancel() }
  }

  func revealLastExport() {
    guard let lastMarkdownURL else { return }
    NSWorkspace.shared.activateFileViewerSelecting([lastMarkdownURL])
  }

}
