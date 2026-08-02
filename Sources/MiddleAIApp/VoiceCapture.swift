import AVFoundation
import FluidAudio
import Foundation

struct CapturedAudio: @unchecked Sendable {
  let samples: [Float]
  let sampleRate: Double
  let duration: TimeInterval
  let peakLevel: Float
}

enum VoiceCaptureError: LocalizedError {
  case microphoneUnavailable
  case microphonePermissionDenied
  case recordingTooShort
  case emptyTranscription

  var errorDescription: String? {
    switch self {
    case .microphoneUnavailable: return "Kein verfügbares Mikrofon gefunden."
    case .microphonePermissionDenied:
      return "Der Mikrofonzugriff für MiddleAI ist nicht erlaubt."
    case .recordingTooShort: return "Die Aufnahme war zu kurz."
    case .emptyTranscription: return "Es wurde keine Sprache erkannt."
    }
  }
}

final class MicrophoneRecorder: @unchecked Sendable {
  private let engine = AVAudioEngine()
  private let lock = NSLock()
  private var chunks: [[Float]] = []
  private var captureSampleRate = 0.0
  private var peakLevel: Float = 0
  private var startedAt: Date?
  private var tapInstalled = false

  func start(onLevel: @escaping @Sendable (Float) -> Void) throws {
    if tapInstalled { _ = stop() }
    let input = engine.inputNode
    let hardwareFormat = input.outputFormat(forBus: 0)
    guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
      throw VoiceCaptureError.microphoneUnavailable
    }
    guard
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: hardwareFormat.sampleRate, channels: 1,
        interleaved: false)
    else { throw VoiceCaptureError.microphoneUnavailable }

    lock.withVoiceLock {
      chunks.removeAll(keepingCapacity: true)
      captureSampleRate = format.sampleRate
      peakLevel = 0
      startedAt = Date()
    }

    input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
      guard let self, let channel = buffer.floatChannelData?.pointee else { return }
      let count = Int(buffer.frameLength)
      guard count > 0 else { return }
      let samples = Array(UnsafeBufferPointer(start: channel, count: count))
      var sum: Float = 0
      for sample in samples { sum += sample * sample }
      let rms = sqrt(sum / Float(count))
      let decibels = 20 * log10(max(rms, 0.000_001))
      let normalized = min(1, max(0, (decibels + 55) / 55))
      self.lock.withVoiceLock {
        self.chunks.append(samples)
        self.peakLevel = max(self.peakLevel, normalized)
      }
      onLevel(normalized)
    }
    tapInstalled = true
    engine.prepare()
    do {
      try engine.start()
    } catch {
      input.removeTap(onBus: 0)
      tapInstalled = false
      throw error
    }
  }

  func stop() -> CapturedAudio {
    if tapInstalled {
      engine.inputNode.removeTap(onBus: 0)
      tapInstalled = false
    }
    engine.stop()
    return lock.withVoiceLock {
      let samples = chunks.flatMap { $0 }
      let rate = captureSampleRate
      let duration = rate > 0 ? Double(samples.count) / rate : 0
      let result = CapturedAudio(
        samples: samples, sampleRate: rate, duration: duration, peakLevel: peakLevel)
      chunks.removeAll(keepingCapacity: true)
      captureSampleRate = 0
      peakLevel = 0
      startedAt = nil
      return result
    }
  }

  func cancel() { _ = stop() }
}

actor ParakeetTranscriber {
  private var manager: AsrManager?
  private var loadingTask: Task<AsrManager, Error>?

  func prepare() async throws {
    _ = try await loadManager()
  }

  func transcribe(_ audio: CapturedAudio) async throws -> String {
    guard audio.duration >= 0.25, audio.samples.count >= 1_600 else {
      throw VoiceCaptureError.recordingTooShort
    }
    let manager = try await loadManager()
    let samples = try AudioConverter().resample(audio.samples, from: audio.sampleRate)
    guard samples.count >= 1_600 else { throw VoiceCaptureError.recordingTooShort }
    let layers = await manager.decoderLayerCount
    var decoderState = try TdtDecoderState(decoderLayers: layers)
    let result = try await manager.transcribe(
      samples, decoderState: &decoderState, language: .german)
    let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { throw VoiceCaptureError.emptyTranscription }
    return text
  }

  private func loadManager() async throws -> AsrManager {
    if let manager { return manager }
    if let loadingTask { return try await loadingTask.value }
    let task = Task.detached(priority: .userInitiated) {
      let models = try await AsrModels.downloadAndLoad(version: .v3)
      return AsrManager(config: .default, models: models)
    }
    loadingTask = task
    do {
      let loaded = try await task.value
      manager = loaded
      loadingTask = nil
      return loaded
    } catch {
      loadingTask = nil
      throw error
    }
  }
}

extension NSLock {
  fileprivate func withVoiceLock<T>(_ body: () -> T) -> T {
    lock()
    defer { unlock() }
    return body()
  }
}
