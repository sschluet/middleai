import AVFoundation
import CoreML
import FluidAudio
import Foundation
import MiddleAICore

struct CapturedAudio: @unchecked Sendable {
  let samples: [Float]
  let sampleRate: Double
  let duration: TimeInterval
  let peakLevel: Float
  let deviceName: String
}

enum VoiceCaptureError: LocalizedError {
  case microphoneUnavailable
  case microphonePermissionDenied
  case recordingTooShort
  case emptyTranscription
  case noAudioSignal(String)

  var errorDescription: String? {
    switch self {
    case .microphoneUnavailable: return "Kein verfügbares Mikrofon gefunden."
    case .microphonePermissionDenied:
      return "Der Mikrofonzugriff für MiddleAI ist nicht erlaubt."
    case .recordingTooShort: return "Die Aufnahme war zu kurz."
    case .emptyTranscription:
      return
        "Die Aufnahme enthielt Audio, aber keine verständliche Sprache. Bitte Mikrofon und Abstand prüfen."
    case .noAudioSignal(let message): return message
    }
  }
}

final class MicrophoneRecorder: @unchecked Sendable {
  private var engine: AVAudioEngine?
  private let lock = NSLock()
  private var chunks: [[Float]] = []
  private var captureSampleRate = 0.0
  private var peakLevel: Float = 0
  private var startedAt: Date?
  private var tapInstalled = false

  func start(deviceUID: String, onLevel: @escaping @Sendable (Float) -> Void) throws {
    if engine != nil { _ = stop() }
    // A fresh engine prevents stale Core Audio device IDs after USB, display or default-device
    // changes. Reusing the previous input node can leave AVAudioEngine bound to a device that
    // macOS has already replaced.
    let recordingEngine = AVAudioEngine()
    let input = recordingEngine.inputNode
    guard let device = AudioInputDeviceCatalog.selectedDevice(for: deviceUID) else {
      throw AudioInputDeviceError.unavailable
    }
    guard let audioUnit = input.audioUnit else { throw VoiceCaptureError.microphoneUnavailable }
    // AVAudioEngine already follows the current macOS input device. Only override
    // the AudioUnit when the user deliberately pinned a concrete microphone.
    if deviceUID != AudioInputDeviceCatalog.systemDefaultUID {
      try AudioInputDeviceCatalog.apply(device, to: audioUnit)
    }
    let availableFormat = input.outputFormat(forBus: 0)
    guard availableFormat.sampleRate > 0, availableFormat.channelCount > 0 else {
      throw VoiceCaptureError.microphoneUnavailable
    }

    lock.withVoiceLock {
      chunks.removeAll(keepingCapacity: true)
      captureSampleRate = 0
      peakLevel = 0
      startedAt = Date()
      activeDeviceName = device.name
    }

    // Passing nil is intentional: AVAudioEngine chooses the input node's negotiated format at
    // the instant the tap is installed. Constructing a mono format from an earlier query races
    // devices such as USB speakerphones that renegotiate between 16, 44.1 and 48 kHz on start.
    input.installTap(onBus: 0, bufferSize: 1_024, format: nil) { [weak self] buffer, _ in
      guard let self else { return }
      let samples = Self.monoSamples(from: buffer)
      guard !samples.isEmpty else { return }
      var sum: Float = 0
      for sample in samples { sum += sample * sample }
      let rms = sqrt(sum / Float(samples.count))
      let decibels = 20 * log10(max(rms, 0.000_001))
      let normalized = min(1, max(0, (decibels + 55) / 55))
      self.lock.withVoiceLock {
        if self.captureSampleRate == 0 { self.captureSampleRate = buffer.format.sampleRate }
        self.chunks.append(samples)
        self.peakLevel = max(self.peakLevel, normalized)
      }
      onLevel(normalized)
    }
    tapInstalled = true
    engine = recordingEngine
    recordingEngine.prepare()
    do {
      try recordingEngine.start()
    } catch {
      input.removeTap(onBus: 0)
      tapInstalled = false
      engine = nil
      throw error
    }
  }

  func stop() -> CapturedAudio {
    let recordingEngine = engine
    if tapInstalled, let recordingEngine {
      recordingEngine.inputNode.removeTap(onBus: 0)
      tapInstalled = false
    }
    recordingEngine?.stop()
    recordingEngine?.reset()
    engine = nil
    return lock.withVoiceLock {
      let samples = chunks.flatMap { $0 }
      let rate = captureSampleRate
      let duration = rate > 0 ? Double(samples.count) / rate : 0
      let result = CapturedAudio(
        samples: samples, sampleRate: rate, duration: duration, peakLevel: peakLevel,
        deviceName: activeDeviceName)
      chunks.removeAll(keepingCapacity: true)
      captureSampleRate = 0
      peakLevel = 0
      startedAt = nil
      activeDeviceName = "Unbekanntes Mikrofon"
      return result
    }
  }

  func cancel() { _ = stop() }

  private var activeDeviceName = "Unbekanntes Mikrofon"

  private static func monoSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
    guard buffer.format.commonFormat == .pcmFormatFloat32,
      let channelData = buffer.floatChannelData
    else { return [] }
    let frameCount = Int(buffer.frameLength)
    let channelCount = Int(buffer.format.channelCount)
    guard frameCount > 0, channelCount > 0 else { return [] }

    var result = [Float](repeating: 0, count: frameCount)
    if buffer.format.isInterleaved {
      let source = channelData[0]
      for frame in 0..<frameCount {
        var mixed: Float = 0
        for channel in 0..<channelCount {
          mixed += source[frame * channelCount + channel]
        }
        result[frame] = mixed / Float(channelCount)
      }
    } else {
      for channel in 0..<channelCount {
        let source = channelData[channel]
        for frame in 0..<frameCount { result[frame] += source[frame] }
      }
      if channelCount > 1 {
        let scale = Float(channelCount)
        for frame in result.indices { result[frame] /= scale }
      }
    }
    return result
  }
}

actor ParakeetTranscriber {
  private var manager: AsrManager?
  private var loadingTask: Task<AsrManager, Error>?
  private var activeSettings: AppConfig.STT?

  func prepare(settings: AppConfig.STT) async throws {
    _ = try await loadManager(settings: settings)
  }

  func transcribe(_ audio: CapturedAudio, settings: AppConfig.STT) async throws -> String {
    guard audio.duration >= 0.25, audio.samples.count >= 1_600 else {
      throw VoiceCaptureError.recordingTooShort
    }
    let manager = try await loadManager(settings: settings)
    let samples = try AudioConverter().resample(audio.samples, from: audio.sampleRate)
    guard samples.count >= 1_600 else { throw VoiceCaptureError.recordingTooShort }
    let layers = await manager.decoderLayerCount
    var decoderState = try TdtDecoderState(decoderLayers: layers)
    let language: Language? = settings.language == "de" ? .german : nil
    let result = try await manager.transcribe(
      samples, decoderState: &decoderState, language: language)
    let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { throw VoiceCaptureError.emptyTranscription }
    return text
  }

  private func loadManager(settings: AppConfig.STT) async throws -> AsrManager {
    if activeSettings != settings {
      loadingTask?.cancel()
      loadingTask = nil
      if let manager { await manager.cleanup() }
      manager = nil
      activeSettings = settings
    }
    if let manager { return manager }
    if let loadingTask { return try await loadingTask.value }
    let selectedSettings = settings
    let task = Task.detached(priority: .userInitiated) {
      let precision: ParakeetEncoderPrecision =
        selectedSettings.encoderPrecision == "int4" ? .int4 : .int8
      let computeUnits: MLComputeUnits? =
        selectedSettings.computeMode == "fast" ? .cpuAndGPU : nil
      let accurateLongForm = selectedSettings.longFormMode == "accurate"
      let asrConfig = ASRConfig(
        melChunkContext: false, dualDecodeArbitration: accurateLongForm)
      let models = try await AsrModels.downloadAndLoad(
        version: .v3, encoderPrecision: precision, encoderComputeUnits: computeUnits)
      return AsrManager(config: asrConfig, models: models)
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
