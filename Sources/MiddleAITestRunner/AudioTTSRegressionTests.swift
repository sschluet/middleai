import Foundation
import MiddleAICore

enum AudioTTSRegressionTests {
  static func testVoiceAccumulator() throws {
    var bounded = VoiceSampleAccumulator(targetSampleRate: 16_000, maximumDuration: 1)
    let source = (0..<48_000).map { index in
      Float(sin(Double(index) * 2 * .pi * 440 / 48_000))
    }
    try expect(bounded.append(source, sampleRate: 48_000), "recording duration limit")
    try expect(bounded.sampleCount == 16_000, "48 kHz to 16 kHz conversion")
    let samples = bounded.removeSamples()
    try expect(samples.count == 16_000 && bounded.sampleCount == 0, "zero-copy handoff")

    var changingRate = VoiceSampleAccumulator(targetSampleRate: 16_000, maximumDuration: 2)
    _ = changingRate.append([Float](repeating: 0.2, count: 4_800), sampleRate: 48_000)
    _ = changingRate.append([Float](repeating: -0.2, count: 4_410), sampleRate: 44_100)
    try expect(abs(changingRate.sampleCount - 3_200) <= 2, "sample-rate change")
    try expect(changingRate.samples.allSatisfy(\.isFinite), "finite converted samples")
  }

  static func testTTSCache() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "middleai-tts-cache-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = TTSAudioCache(directory: directory)
    let audio = makeWAV(sampleCount: 320)
    let first = TTSAudioCache.key(
      provider: "test", voice: "de", rate: 1, text: "Vertraulich eins")
    let second = TTSAudioCache.key(
      provider: "test", voice: "de", rate: 1, text: "Vertraulich zwei")

    try await cache.store(audio, for: first, maximumBytes: 10_000)
    let hit = await cache.data(for: first, maximumBytes: 10_000)
    try expect(hit == audio, "cache hit")
    let directoryMode =
      try FileManager.default.attributesOfItem(atPath: directory.path)[
        .posixPermissions] as? NSNumber
    let firstURL = directory.appendingPathComponent("\(first).wav")
    let fileMode =
      try FileManager.default.attributesOfItem(atPath: firstURL.path)[
        .posixPermissions] as? NSNumber
    try expect(((directoryMode?.intValue ?? 0) & 0o777) == 0o700, "private cache directory")
    try expect(((fileMode?.intValue ?? 0) & 0o777) == 0o600, "private cache file")

    try Data("RIFFbad-WAVE".utf8).write(to: firstURL, options: .atomic)
    let corrupt = await cache.data(for: first, maximumBytes: 10_000)
    try expect(corrupt == nil, "corrupt cache rejection")
    try expect(!FileManager.default.fileExists(atPath: firstURL.path), "corrupt cache cleanup")

    try await cache.store(audio, for: first, maximumBytes: Int64(audio.count + 100))
    try await Task.sleep(for: .milliseconds(20))
    try await cache.store(audio, for: second, maximumBytes: Int64(audio.count + 100))
    let pruned = await cache.data(for: first, maximumBytes: 10_000)
    let newest = await cache.data(for: second, maximumBytes: 10_000)
    try expect(pruned == nil && newest == audio, "least-recently-used cache pruning")
  }

  @MainActor static func testTTSQueueConcurrency() async throws {
    let preparing = QueueTestTTS()
    let queue = TTSQueue(provider: preparing)
    async let first: Void = queue.prepare()
    async let second: Void = queue.prepare()
    _ = try await (first, second)
    try expect(preparing.prepareCount == 1, "coalesced provider preparation")

    let failing = QueueTestTTS(failure: QueueTestError.failed)
    var surfacedError = ""
    let failingQueue = TTSQueue(provider: failing) { surfacedError = $0 }
    failingQueue.enqueue("Fehler")
    do {
      try await failingQueue.waitUntilIdle()
      throw TestFailure.failed("TTS failure propagated")
    } catch let error as TestFailure {
      throw error
    } catch {
      try expect(error.localizedDescription.contains("Testfehler"), "queue error detail")
    }
    try expect(surfacedError.contains("Testfehler"), "queue error callback")

    let cancellable = QueueTestTTS(speakDelay: .seconds(2))
    let cancellingQueue = TTSQueue(provider: cancellable)
    cancellingQueue.enqueue("Abbrechen")
    try await Task.sleep(for: .milliseconds(20))
    cancellingQueue.stop()
    try await cancellingQueue.waitUntilIdle()
    try expect(cancellable.didStop, "provider cancellation")
    try expect(cancellingQueue.lastErrorMessage == nil, "cancellation is not a TTS error")
  }

  private static func makeWAV(sampleCount: Int) -> Data {
    let dataSize = UInt32(sampleCount * MemoryLayout<Int16>.size)
    var data = Data()
    data.append(Data("RIFF".utf8))
    data.appendTTSInteger(UInt32(36) + dataSize)
    data.append(Data("WAVEfmt ".utf8))
    data.appendTTSInteger(UInt32(16))
    data.appendTTSInteger(UInt16(1))
    data.appendTTSInteger(UInt16(1))
    data.appendTTSInteger(UInt32(16_000))
    data.appendTTSInteger(UInt32(32_000))
    data.appendTTSInteger(UInt16(2))
    data.appendTTSInteger(UInt16(16))
    data.append(Data("data".utf8))
    data.appendTTSInteger(dataSize)
    for _ in 0..<sampleCount { data.appendTTSInteger(Int16(0)) }
    return data
  }
}

private enum QueueTestError: LocalizedError {
  case failed
  var errorDescription: String? { "Testfehler in der Sprachausgabe" }
}

@MainActor private final class QueueTestTTS: TTSProvider {
  private let failure: Error?
  private let speakDelay: Duration
  private(set) var prepareCount = 0
  private(set) var didStop = false
  var isSpeaking = false

  init(failure: Error? = nil, speakDelay: Duration = .milliseconds(5)) {
    self.failure = failure
    self.speakDelay = speakDelay
  }

  func prepare() async throws {
    prepareCount += 1
    try await Task.sleep(for: .milliseconds(40))
  }

  func speak(_ text: String) async throws {
    isSpeaking = true
    defer { isSpeaking = false }
    if let failure { throw failure }
    try await Task.sleep(for: speakDelay)
  }

  func stop() {
    didStop = true
    isSpeaking = false
  }
}

extension Data {
  fileprivate mutating func appendTTSInteger<T: FixedWidthInteger>(_ value: T) {
    var littleEndian = value.littleEndian
    Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
  }
}
