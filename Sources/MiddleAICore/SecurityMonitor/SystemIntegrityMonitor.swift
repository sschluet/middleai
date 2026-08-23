import CryptoKit
import Foundation

public enum IntegritySeverity: Int, Codable, CaseIterable, Comparable, Sendable {
  case info = 0
  case warning = 1
  case critical = 2

  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

  public var title: String {
    switch self {
    case .info: return "Hinweis"
    case .warning: return "Warnung"
    case .critical: return "Kritisch"
    }
  }
}

public enum IntegrityCategory: String, Codable, CaseIterable, Sendable {
  case deviceManagement
  case securityConfiguration
  case persistence
  case identity
  case certificates
  case network
  case system
  case middleAI

  public var title: String {
    switch self {
    case .deviceManagement: return "Intune und Geräteverwaltung"
    case .securityConfiguration: return "Sicherheitskonfiguration"
    case .persistence: return "Autostart und Persistenz"
    case .identity: return "Benutzer und Administratoren"
    case .certificates: return "Zertifikate"
    case .network: return "Netzwerk"
    case .system: return "macOS-System"
    case .middleAI: return "MiddleAI-Schutz"
    }
  }
}

public struct IntegrityArtifact: Codable, Equatable, Hashable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case configurationProfile
    case managedPreference
    case systemExtension
    case launchAgent
    case launchDaemon
    case privilegedHelper
    case rootCertificate
  }

  public var kind: Kind
  public var identifier: String
  public var digest: String
  public var teamIdentifier: String?
  public var signed: Bool?

  public init(
    kind: Kind, identifier: String, digest: String, teamIdentifier: String? = nil,
    signed: Bool? = nil
  ) {
    self.kind = kind
    self.identifier = String(identifier.prefix(300))
    self.digest = digest
    self.teamIdentifier = teamIdentifier.map { String($0.prefix(80)) }
    self.signed = signed
  }

  public var stableKey: String { "\(kind.rawValue)|\(identifier.lowercased())" }
}

public struct IntegritySignal: Codable, Equatable, Hashable, Sendable {
  public var category: IntegrityCategory
  public var identifier: String
  public var summary: String
  public var severity: IntegritySeverity
  public var count: Int

  public init(
    category: IntegrityCategory, identifier: String, summary: String,
    severity: IntegritySeverity, count: Int = 1
  ) {
    self.category = category
    self.identifier = String(identifier.prefix(200))
    self.summary = Self.safeSummary(summary)
    self.severity = severity
    self.count = max(1, count)
  }

  private static func safeSummary(_ value: String) -> String {
    let withoutControl = value.unicodeScalars.filter {
      !CharacterSet.controlCharacters.contains($0) || $0 == "\n"
    }
    return String(String.UnicodeScalarView(withoutControl)).prefixString(500)
  }
}

public struct SystemIntegritySnapshot: Codable, Equatable, Sendable {
  public static let currentVersion = 1
  public var version: Int
  public var capturedAt: Date
  /// Values are deliberately normalized states or hashes, never complete command output.
  public var states: [String: String]
  public var artifacts: [IntegrityArtifact]
  public var signals: [IntegritySignal]
  public var unavailableSources: [String]

  public init(
    capturedAt: Date = Date(), states: [String: String] = [:],
    artifacts: [IntegrityArtifact] = [], signals: [IntegritySignal] = [],
    unavailableSources: [String] = []
  ) {
    self.version = Self.currentVersion
    self.capturedAt = capturedAt
    self.states = states
    self.artifacts = Dictionary(grouping: artifacts, by: \.stableKey).values.map {
      Self.consolidated($0)
    }.sorted { $0.stableKey < $1.stableKey }
    self.signals = signals
    self.unavailableSources = unavailableSources.sorted()
  }

  public var fingerprint: String {
    var material = states.keys.sorted().map { "\($0)=\(states[$0] ?? "")" }
    material += artifacts.map {
      "\($0.stableKey)=\($0.digest)|\($0.teamIdentifier ?? "")|\($0.signed.map(String.init) ?? "")"
    }
    return IntegrityHash.sha256(material.joined(separator: "\n"))
  }

  private static func consolidated(_ values: [IntegrityArtifact]) -> IntegrityArtifact {
    guard var result = values.first, values.count > 1 else {
      return values[0]
    }
    result.digest = IntegrityHash.sha256(values.map(\.digest).sorted().joined(separator: "|"))
    let teams = Set(values.compactMap(\.teamIdentifier)).sorted()
    result.teamIdentifier = teams.isEmpty ? nil : teams.joined(separator: ",").prefixString(80)
    let signatures = values.compactMap(\.signed)
    result.signed = signatures.isEmpty ? nil : !signatures.contains(false)
    return result
  }
}

public struct IntegrityFinding: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var detectedAt: Date
  public var severity: IntegritySeverity
  public var category: IntegrityCategory
  public var title: String
  public var detail: String
  public var evidence: String
  public var occurrenceCount: Int
  public var localExplanation: String?
  public var simulated: Bool

  public init(
    detectedAt: Date = Date(), severity: IntegritySeverity, category: IntegrityCategory,
    title: String, detail: String, evidence: String = "", occurrenceCount: Int = 1,
    localExplanation: String? = nil, simulated: Bool = false, identityMaterial: String? = nil
  ) {
    self.detectedAt = detectedAt
    self.severity = severity
    self.category = category
    self.title = title.prefixString(180)
    self.detail = detail.prefixString(1_200)
    self.evidence = evidence.prefixString(600)
    self.occurrenceCount = max(1, occurrenceCount)
    self.localExplanation = localExplanation?.prefixString(1_200)
    self.simulated = simulated
    self.id = IntegrityHash.sha256(
      identityMaterial ?? "\(category.rawValue)|\(self.title)|\(self.evidence)")
  }
}

public struct IntegrityScanResult: Equatable, Sendable {
  public var snapshot: SystemIntegritySnapshot
  public var findings: [IntegrityFinding]
  public var baselineAvailable: Bool

  public init(
    snapshot: SystemIntegritySnapshot, findings: [IntegrityFinding], baselineAvailable: Bool
  ) {
    self.snapshot = snapshot
    self.findings = findings
    self.baselineAvailable = baselineAvailable
  }
}

public struct SystemIntegrityRuleEngine: Sendable {
  public init() {}

  public func evaluate(
    baseline: SystemIntegritySnapshot?, current: SystemIntegritySnapshot, now: Date = Date()
  ) -> IntegrityScanResult {
    var findings = current.signals.map { finding(for: $0, now: now) }
    guard let baseline else {
      return IntegrityScanResult(
        snapshot: current, findings: findings.sorted(by: Self.sortFindings),
        baselineAvailable: false)
    }

    // A temporarily unavailable command must never look like a security-state removal.
    for key in Set(baseline.states.keys).intersection(current.states.keys).sorted() {
      let old = baseline.states[key] ?? ""
      let new = current.states[key] ?? ""
      guard old != new else { continue }
      findings.append(stateFinding(key: key, old: old, new: new, now: now))
    }

    let oldArtifacts = Dictionary(
      uniqueKeysWithValues: baseline.artifacts.map { ($0.stableKey, $0) })
    let newArtifacts = Dictionary(
      uniqueKeysWithValues: current.artifacts.map { ($0.stableKey, $0) })
    let unavailableArtifactKinds = Set(
      current.unavailableSources.compactMap { source -> String? in
        let prefix = "artifacts."
        guard source.hasPrefix(prefix) else { return nil }
        return String(source.dropFirst(prefix.count))
      })
    for key in Set(oldArtifacts.keys).union(newArtifacts.keys).sorted() {
      let kind = oldArtifacts[key]?.kind ?? newArtifacts[key]?.kind
      if let kind, unavailableArtifactKinds.contains(kind.rawValue) { continue }
      switch (oldArtifacts[key], newArtifacts[key]) {
      case (nil, let artifact?): findings.append(artifactAdded(artifact, now: now))
      case (let artifact?, nil): findings.append(artifactRemoved(artifact, now: now))
      case (let old?, let new?) where old != new:
        findings.append(artifactChanged(old: old, new: new, now: now))
      default: break
      }
    }

    let unique = Dictionary(grouping: findings, by: \.id).compactMap { _, values in
      values.max { $0.severity < $1.severity }
    }
    return IntegrityScanResult(
      snapshot: current, findings: unique.sorted(by: Self.sortFindings),
      baselineAvailable: true)
  }

  public func simulatedFinding(_ severity: IntegritySeverity, now: Date = Date())
    -> IntegrityFinding
  {
    switch severity {
    case .info:
      return IntegrityFinding(
        detectedAt: now, severity: .info, category: .deviceManagement,
        title: "Test: Intune-Profil aktualisiert",
        detail:
          "Ein verwaltetes Profil wurde ohne erkennbare Sicherheitsverschlechterung geändert.",
        evidence: "Interne Simulation · keine Systemeinstellung wurde verändert", simulated: true)
    case .warning:
      return IntegrityFinding(
        detectedAt: now, severity: .warning, category: .persistence,
        title: "Test: Neuer LaunchAgent",
        detail: "Ein neuer signierter Autostarteintrag weicht vom bestätigten Sollzustand ab.",
        evidence: "Interne Simulation · keine Datei wurde angelegt", simulated: true)
    case .critical:
      return IntegrityFinding(
        detectedAt: now, severity: .critical, category: .securityConfiguration,
        title: "Test: Firewall deaktiviert",
        detail:
          "Eine zentrale Schutzfunktion wurde gegenüber dem bestätigten Sollzustand abgeschwächt.",
        evidence: "Interne Simulation · die Firewall blieb unverändert", simulated: true)
    }
  }

  private func stateFinding(
    key: String, old: String, new: String, now: Date
  ) -> IntegrityFinding {
    let metadata =
      Self.stateMetadata[key] ?? (
        .warning, .system, "Systemzustand verändert"
      )
    var severity = metadata.0
    if Self.securityDegradationKeys.contains(key), Self.isDisabled(new) { severity = .critical }
    if key == "identity.admin_members" || key == "certificates.system_roots" {
      severity = .critical
    }
    return IntegrityFinding(
      detectedAt: now, severity: severity, category: metadata.1, title: metadata.2,
      detail: "Der aktuelle Zustand weicht von der ausdrücklich bestätigten Baseline ab.",
      evidence:
        "Vorher: \(Self.redactedValue(old, key: key)) · Jetzt: \(Self.redactedValue(new, key: key))",
      identityMaterial: "state|\(key)|\(old)|\(new)")
  }

  private func artifactAdded(_ artifact: IntegrityArtifact, now: Date) -> IntegrityFinding {
    let metadata = Self.artifactMetadata(artifact.kind)
    let unsignedCritical = artifact.signed == false && artifact.kind != .configurationProfile
    let severity: IntegritySeverity = unsignedCritical ? .critical : metadata.severity
    return IntegrityFinding(
      detectedAt: now, severity: severity, category: metadata.category,
      title: "Neu: \(artifact.identifier)",
      detail: unsignedCritical
        ? "Ein nicht gültig signierter Persistenz- oder Systemeintrag wurde hinzugefügt."
        : "Ein neuer \(metadata.singular) weicht vom bestätigten Sollzustand ab.",
      evidence: Self.artifactEvidence(artifact),
      identityMaterial: "artifact-added|\(artifact.stableKey)|\(artifact.digest)")
  }

  private func artifactRemoved(_ artifact: IntegrityArtifact, now: Date) -> IntegrityFinding {
    let metadata = Self.artifactMetadata(artifact.kind)
    let severity: IntegritySeverity = artifact.kind == .configurationProfile ? .warning : .warning
    return IntegrityFinding(
      detectedAt: now, severity: severity, category: metadata.category,
      title: "Entfernt: \(artifact.identifier)",
      detail: "Ein zuvor bestätigter \(metadata.singular) ist nicht mehr vorhanden.",
      evidence: Self.artifactEvidence(artifact),
      identityMaterial: "artifact-removed|\(artifact.stableKey)|\(artifact.digest)")
  }

  private func artifactChanged(
    old: IntegrityArtifact, new: IntegrityArtifact, now: Date
  ) -> IntegrityFinding {
    let metadata = Self.artifactMetadata(new.kind)
    let signatureRegressed = old.signed != false && new.signed == false
    return IntegrityFinding(
      detectedAt: now, severity: signatureRegressed ? .critical : .warning,
      category: metadata.category, title: "Verändert: \(new.identifier)",
      detail: signatureRegressed
        ? "Die Signatur eines zuvor bestätigten Eintrags ist nicht mehr gültig."
        : "Der Inhalt eines bestätigten \(metadata.singular) wurde verändert.",
      evidence: Self.artifactEvidence(new),
      identityMaterial: "artifact-changed|\(new.stableKey)|\(old.digest)|\(new.digest)")
  }

  private func finding(for signal: IntegritySignal, now: Date) -> IntegrityFinding {
    IntegrityFinding(
      detectedAt: now, severity: signal.severity, category: signal.category,
      title: signal.summary, detail: "Das Ereignis wurde in lokalen macOS-Daten erkannt.",
      evidence: signal.count > 1 ? "\(signal.count) gleichartige Ereignisse" : "Ein Ereignis",
      occurrenceCount: signal.count,
      identityMaterial: "signal|\(signal.identifier)|\(signal.summary)")
  }

  private static func sortFindings(_ lhs: IntegrityFinding, _ rhs: IntegrityFinding) -> Bool {
    if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
    return lhs.detectedAt > rhs.detectedAt
  }

  private static let securityDegradationKeys: Set<String> = [
    "security.firewall", "security.filevault", "security.gatekeeper", "security.sip",
    "security.stealth_mode",
  ]

  private static let stateMetadata: [String: (IntegritySeverity, IntegrityCategory, String)] = [
    "security.firewall": (.critical, .securityConfiguration, "Firewall-Zustand verändert"),
    "security.filevault": (.critical, .securityConfiguration, "FileVault-Zustand verändert"),
    "security.gatekeeper": (.critical, .securityConfiguration, "Gatekeeper-Zustand verändert"),
    "security.sip": (.critical, .securityConfiguration, "Systemintegritätsschutz verändert"),
    "security.stealth_mode": (.warning, .securityConfiguration, "Firewall-Stealth-Modus verändert"),
    "security.remote_login": (.critical, .securityConfiguration, "SSH-Fernzugriff verändert"),
    "security.remote_management": (
      .critical, .securityConfiguration, "Remote Management verändert"
    ),
    "mdm.enrollment": (.critical, .deviceManagement, "MDM-Anmeldung verändert"),
    "mdm.server": (.critical, .deviceManagement, "MDM-Server verändert"),
    "identity.admin_members": (.critical, .identity, "Lokale Administratoren verändert"),
    "identity.local_users": (.critical, .identity, "Lokale Benutzerkonten verändert"),
    "certificates.system_roots": (.critical, .certificates, "Systemzertifikate verändert"),
    "network.proxy": (.warning, .network, "Proxy-Konfiguration verändert"),
    "network.dns": (.warning, .network, "DNS-Konfiguration verändert"),
    "middleai.bundle": (.critical, .middleAI, "MiddleAI-Programmdatei verändert"),
  ]

  private static func artifactMetadata(_ kind: IntegrityArtifact.Kind) -> (
    severity: IntegritySeverity, category: IntegrityCategory, singular: String
  ) {
    switch kind {
    case .configurationProfile: return (.warning, .deviceManagement, "Konfigurationsprofil")
    case .managedPreference: return (.warning, .deviceManagement, "verwaltete Einstellung")
    case .systemExtension: return (.warning, .securityConfiguration, "Systemerweiterung")
    case .launchAgent: return (.warning, .persistence, "LaunchAgent")
    case .launchDaemon: return (.warning, .persistence, "LaunchDaemon")
    case .privilegedHelper: return (.critical, .persistence, "privilegierter Hilfsprozess")
    case .rootCertificate: return (.critical, .certificates, "Root-Zertifikat")
    }
  }

  private static func artifactEvidence(_ artifact: IntegrityArtifact) -> String {
    var parts = ["Typ: \(artifact.kind.rawValue)"]
    if let team = artifact.teamIdentifier { parts.append("Team-ID: \(team)") }
    if let signed = artifact.signed {
      parts.append(signed ? "Signatur gültig" : "Signatur ungültig")
    }
    return parts.joined(separator: " · ")
  }

  private static func redactedValue(_ value: String, key: String) -> String {
    if key.hasPrefix("identity.") || key == "mdm.server"
      || key == "security.remote_management" || key == "middleai.bundle"
      || key.contains("certificates") || key.contains("proxy") || key.contains("dns")
    {
      return "Fingerabdruck \(value.prefix(12))"
    }
    return value.prefixString(160)
  }

  private static func isDisabled(_ value: String) -> Bool {
    let normalized = value.lowercased()
    return normalized.contains("disabled") || normalized.contains("off")
      || normalized == "false" || normalized == "0"
  }
}

public enum IntegrityHistoryStatus: Equatable, Sendable {
  case empty
  case valid(Int)
  case corrupted
}

public actor SystemIntegrityStore {
  private struct BaselineDocument: Codable {
    var version = 1
    var snapshot: SystemIntegritySnapshot
    var hash: String
  }
  private struct HistoryRecord: Codable {
    var finding: IntegrityFinding
    var previousHash: String
    var hash: String
  }
  private struct HistoryDocument: Codable {
    var version = 1
    var records: [HistoryRecord]
  }

  public static var defaultDirectory: URL {
    ConfigLoader.defaultDirectory.appendingPathComponent("system-integrity", isDirectory: true)
  }

  private let directory: URL
  private var historyStatus: IntegrityHistoryStatus = .empty

  public init(directory: URL = defaultDirectory) { self.directory = directory }

  public func baseline() throws -> SystemIntegritySnapshot? {
    guard let document = try decodeIfPresent(BaselineDocument.self, from: baselineURL) else {
      return nil
    }
    guard document.hash == Self.baselineHash(document.snapshot) else {
      throw MiddleAIError.configuration("Die lokale Integritäts-Baseline wurde verändert.")
    }
    return document.snapshot
  }

  public func saveBaseline(_ snapshot: SystemIntegritySnapshot) throws {
    try secureWrite(
      BaselineDocument(snapshot: snapshot, hash: Self.baselineHash(snapshot)), to: baselineURL)
  }

  public func removeBaseline() throws {
    if FileManager.default.fileExists(atPath: baselineURL.path) {
      try FileManager.default.removeItem(at: baselineURL)
    }
  }

  public func findings() throws -> [IntegrityFinding] {
    guard let document = try decodeIfPresent(HistoryDocument.self, from: historyURL) else {
      historyStatus = .empty
      return []
    }
    guard Self.valid(document.records) else {
      historyStatus = .corrupted
      throw MiddleAIError.configuration(
        "Die lokale Integritätshistorie hat eine ungültige Hash-Kette.")
    }
    historyStatus = .valid(document.records.count)
    return document.records.map(\.finding).sorted { $0.detectedAt > $1.detectedAt }
  }

  public func append(_ additions: [IntegrityFinding], retentionDays: Int, now: Date = Date()) throws
  {
    guard !additions.isEmpty else { return }
    var existing = try findings()
    for finding in additions where !finding.simulated {
      if let index = existing.firstIndex(where: { $0.id == finding.id }) {
        existing[index].detectedAt = finding.detectedAt
        existing[index].occurrenceCount += finding.occurrenceCount
        existing[index].severity = max(existing[index].severity, finding.severity)
        existing[index].localExplanation =
          finding.localExplanation ?? existing[index].localExplanation
      } else {
        existing.append(finding)
      }
    }
    if retentionDays > 0,
      let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: now)
    {
      existing.removeAll { $0.detectedAt < cutoff }
    }
    existing.sort { $0.detectedAt < $1.detectedAt }
    if existing.count > 500 { existing.removeFirst(existing.count - 500) }
    let records = Self.records(for: existing)
    try secureWrite(HistoryDocument(records: records), to: historyURL)
    historyStatus = .valid(records.count)
  }

  public func clearFindings() throws {
    if FileManager.default.fileExists(atPath: historyURL.path) {
      try FileManager.default.removeItem(at: historyURL)
    }
    historyStatus = .empty
  }

  public func status() -> IntegrityHistoryStatus { historyStatus }

  private var baselineURL: URL { directory.appendingPathComponent("baseline.json") }
  private var historyURL: URL { directory.appendingPathComponent("findings.json") }

  private func secureWrite<T: Encodable>(_ value: T, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o700))], ofItemAtPath: directory.path)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(value).write(to: url, options: [.atomic])
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: url.path)
  }

  private func decodeIfPresent<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(type, from: Data(contentsOf: url))
  }

  private static func records(for findings: [IntegrityFinding]) -> [HistoryRecord] {
    var previous = "middleai-integrity-history-v1"
    return findings.map { finding in
      let material = canonical(finding)
      let hash = IntegrityHash.sha256("\(previous)|\(material)")
      defer { previous = hash }
      return HistoryRecord(finding: finding, previousHash: previous, hash: hash)
    }
  }

  private static func valid(_ records: [HistoryRecord]) -> Bool {
    var previous = "middleai-integrity-history-v1"
    for record in records {
      guard record.previousHash == previous,
        record.hash == IntegrityHash.sha256("\(previous)|\(canonical(record.finding))")
      else { return false }
      previous = record.hash
    }
    return true
  }

  private static func canonical(_ finding: IntegrityFinding) -> String {
    "\(finding.id)|\(Int(finding.detectedAt.timeIntervalSince1970))|\(finding.severity.rawValue)|\(finding.category.rawValue)|\(finding.title)|\(finding.detail)|\(finding.evidence)|\(finding.occurrenceCount)|\(finding.localExplanation ?? "")"
  }

  private static func baselineHash(_ snapshot: SystemIntegritySnapshot) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    let encoded = (try? encoder.encode(snapshot)) ?? Data(snapshot.fingerprint.utf8)
    return IntegrityHash.sha256(Data("middleai-integrity-baseline-v1|".utf8) + encoded)
  }
}

public enum IntegrityHash {
  public static func sha256(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  public static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

extension String {
  fileprivate func prefixString(_ maximum: Int) -> String { String(prefix(maximum)) }
}
