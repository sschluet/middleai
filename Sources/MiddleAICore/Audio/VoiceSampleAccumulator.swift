import Foundation

/// Incrementally converts microphone chunks to bounded 16 kHz mono storage.
/// Only a tiny source-rate tail is retained, so stopping does not require a second full copy.
public struct VoiceSampleAccumulator: Sendable {
  public let targetSampleRate: Double
  public let maximumDuration: TimeInterval

  private var output: [Float]
  private var sourceTail: [Float] = []
  private var sourcePosition = 0.0
  private var sourceRate = 0.0

  public init(targetSampleRate: Double = 16_000, maximumDuration: TimeInterval = 120) {
    self.targetSampleRate = targetSampleRate
    self.maximumDuration = maximumDuration
    self.output = []
    self.output.reserveCapacity(Int(targetSampleRate * min(maximumDuration, 30)))
  }

  public var samples: [Float] { output }
  public var sampleCount: Int { output.count }
  public var duration: TimeInterval { Double(output.count) / targetSampleRate }
  public var reachedLimit: Bool { output.count >= maximumSampleCount }

  /// Returns true when the configured recording limit has been reached.
  @discardableResult public mutating func append(
    _ monoSamples: [Float], sampleRate: Double
  ) -> Bool {
    guard !monoSamples.isEmpty, sampleRate.isFinite, sampleRate > 0, !reachedLimit else {
      return reachedLimit
    }
    if abs(sourceRate - sampleRate) > 0.5 {
      sourceRate = sampleRate
      sourceTail.removeAll(keepingCapacity: true)
      sourcePosition = 0
    }

    if abs(sampleRate - targetSampleRate) < 0.5 {
      let remaining = maximumSampleCount - output.count
      output.append(contentsOf: monoSamples.prefix(remaining))
      return reachedLimit
    }

    sourceTail.append(contentsOf: monoSamples)
    let step = sampleRate / targetSampleRate
    while sourcePosition + 1 < Double(sourceTail.count), output.count < maximumSampleCount {
      let lower = Int(sourcePosition)
      let fraction = Float(sourcePosition - Double(lower))
      let sample = sourceTail[lower] + (sourceTail[lower + 1] - sourceTail[lower]) * fraction
      output.append(sample)
      sourcePosition += step
    }
    let consumed = min(Int(sourcePosition), max(0, sourceTail.count - 1))
    if consumed > 0 {
      sourceTail.removeFirst(consumed)
      sourcePosition -= Double(consumed)
    }
    return reachedLimit
  }

  public mutating func removeSamples() -> [Float] {
    sourceTail.removeAll(keepingCapacity: false)
    sourcePosition = 0
    sourceRate = 0
    let result = output
    output = []
    return result
  }

  private var maximumSampleCount: Int {
    max(1, Int(targetSampleRate * maximumDuration))
  }
}
