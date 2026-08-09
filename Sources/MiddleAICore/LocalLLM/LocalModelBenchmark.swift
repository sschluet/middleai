import Foundation

public struct LocalRuntimeResources: Codable, Equatable, Sendable {
  public let physicalMemoryBytes: UInt64
  public let availableDiskBytes: Int64?
  public let processorCount: Int
  public let activeProcessorCount: Int
  public let thermalState: String
  public let lowPowerModeEnabled: Bool

  public init(
    physicalMemoryBytes: UInt64, availableDiskBytes: Int64?, processorCount: Int,
    activeProcessorCount: Int, thermalState: String = "nominal",
    lowPowerModeEnabled: Bool = false
  ) {
    self.physicalMemoryBytes = physicalMemoryBytes
    self.availableDiskBytes = availableDiskBytes
    self.processorCount = processorCount
    self.activeProcessorCount = activeProcessorCount
    self.thermalState = thermalState
    self.lowPowerModeEnabled = lowPowerModeEnabled
  }

  public static func current(at url: URL = ConfigLoader.defaultDirectory) -> Self {
    let values = try? url.deletingLastPathComponent().resourceValues(
      forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    let process = ProcessInfo.processInfo
    return Self(
      physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
      availableDiskBytes: values?.volumeAvailableCapacityForImportantUsage,
      processorCount: process.processorCount,
      activeProcessorCount: process.activeProcessorCount,
      thermalState: thermalStateName(process.thermalState),
      lowPowerModeEnabled: process.isLowPowerModeEnabled)
  }

  public var recommendedMaximumModelBillions: Int {
    let gib = physicalMemoryBytes / 1_073_741_824
    switch gib {
    case ..<12: return 4
    case ..<20: return 8
    case ..<32: return 14
    case ..<64: return 32
    default: return 70
    }
  }

  private static func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
    switch state {
    case .nominal: return "nominal"
    case .fair: return "fair"
    case .serious: return "serious"
    case .critical: return "critical"
    @unknown default: return "unknown"
    }
  }
}

public struct LocalModelBenchmarkReport: Codable, Equatable, Sendable {
  public let model: String
  public let responseCharacters: Int
  public let estimatedOutputTokens: Int
  public let timeToFirstTokenSeconds: Double?
  public let totalDurationSeconds: Double
  public let estimatedTokensPerSecond: Double
  public let resources: LocalRuntimeResources

  public var isInteractive: Bool {
    (timeToFirstTokenSeconds ?? .infinity) <= 3 && estimatedTokensPerSecond >= 5
  }
}

/// A deliberately short real request gives a more useful device-specific result than deriving
/// performance from a model name or file size. The answer is not stored as a conversation.
public struct LocalModelBenchmarkService: Sendable {
  private let client: any AssistantClientProtocol

  public init(client: any AssistantClientProtocol) { self.client = client }

  public func run(model: String) async throws -> LocalModelBenchmarkReport {
    let clock = BenchmarkTokenClock()
    let start = Date()
    let response = try await client.send(
      messages: [
        Message(
          role: .system,
          content: "Antworte knapp auf Deutsch. Dies ist ein lokaler Leistungstest."),
        Message(role: .user, content: "Nenne in drei Sätzen Vorteile lokaler KI."),
      ], chatID: "benchmark-\(UUID().uuidString)", model: model
    ) { _ in
      clock.markFirstToken()
    }
    let total = max(0.001, Date().timeIntervalSince(start))
    let estimatedTokens = max(1, Int(ceil(Double(response.count) / 4)))
    return LocalModelBenchmarkReport(
      model: model, responseCharacters: response.count,
      estimatedOutputTokens: estimatedTokens,
      timeToFirstTokenSeconds: clock.firstTokenDate.map { $0.timeIntervalSince(start) },
      totalDurationSeconds: total,
      estimatedTokensPerSecond: Double(estimatedTokens) / total,
      resources: .current())
  }
}

private final class BenchmarkTokenClock: @unchecked Sendable {
  private let lock = NSLock()
  private var storedFirstTokenDate: Date?

  var firstTokenDate: Date? {
    lock.lock()
    defer { lock.unlock() }
    return storedFirstTokenDate
  }

  func markFirstToken() {
    lock.lock()
    defer { lock.unlock() }
    if storedFirstTokenDate == nil { storedFirstTokenDate = Date() }
  }
}
