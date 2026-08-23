import CryptoKit
import Foundation
import Security

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

public enum IntegritySourceKind: String, Codable, Sendable {
  case file
  case systemSettings
  case application
  case console
  case keychain
  case profile
}

public struct IntegrityFindingSource: Codable, Equatable, Hashable, Sendable {
  public var kind: IntegritySourceKind
  public var title: String
  /// A collector-controlled local path, application path or System Settings URL.
  public var locator: String
  public var detail: String?
  /// Stable coverage identifier used to keep findings open during a collector outage.
  public var collectorID: String?

  public init(
    kind: IntegritySourceKind, title: String, locator: String, detail: String? = nil,
    collectorID: String? = nil
  ) {
    self.kind = kind
    self.title = String(title.prefix(160))
    self.locator = String(locator.prefix(1_000))
    self.detail = detail.map { String($0.prefix(300)) }
    self.collectorID = collectorID.map { String($0.prefix(160)) }
  }
}

public struct IntegrityArtifact: Codable, Equatable, Hashable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case configurationProfile
    case managedPreference
    case systemExtension
    case systemCertificate
    case launchAgent
    case launchDaemon
    case privilegedHelper
    case rootCertificate
    case loginItem
    case scheduledTask
    case authorizedKey
    case shellStartup
  }

  public var kind: Kind
  public var identifier: String
  public var digest: String
  public var teamIdentifier: String?
  public var signed: Bool?
  public var source: IntegrityFindingSource?
  public var risk: IntegritySeverity?

  public init(
    kind: Kind, identifier: String, digest: String, teamIdentifier: String? = nil,
    signed: Bool? = nil, source: IntegrityFindingSource? = nil,
    risk: IntegritySeverity? = nil
  ) {
    self.kind = kind
    self.identifier = String(identifier.prefix(300))
    self.digest = digest
    self.teamIdentifier = teamIdentifier.map { String($0.prefix(80)) }
    self.signed = signed
    self.source = source
    self.risk = risk
  }

  public var stableKey: String { "\(kind.rawValue)|\(identifier.lowercased())" }
}

public struct IntegritySignal: Codable, Equatable, Hashable, Sendable {
  public var category: IntegrityCategory
  public var identifier: String
  public var summary: String
  public var severity: IntegritySeverity
  public var count: Int
  public var source: IntegrityFindingSource?

  public init(
    category: IntegrityCategory, identifier: String, summary: String,
    severity: IntegritySeverity, count: Int = 1, source: IntegrityFindingSource? = nil
  ) {
    self.category = category
    self.identifier = String(identifier.prefix(200))
    self.summary = Self.safeSummary(summary)
    self.severity = severity
    self.count = max(1, count)
    self.source = source
  }

  private static func safeSummary(_ value: String) -> String {
    let withoutControl = value.unicodeScalars.filter {
      !CharacterSet.controlCharacters.contains($0) || $0 == "\n"
    }
    return String(String.UnicodeScalarView(withoutControl)).prefixString(500)
  }
}

public struct SystemIntegritySnapshot: Codable, Equatable, Sendable {
  public static let currentVersion = 2
  public var version: Int
  public var capturedAt: Date
  /// Values are deliberately normalized states or hashes, never complete command output.
  public var states: [String: String]
  public var artifacts: [IntegrityArtifact]
  public var signals: [IntegritySignal]
  public var unavailableSources: [String]
  public var checkedSources: [String]?

  public init(
    capturedAt: Date = Date(), states: [String: String] = [:],
    artifacts: [IntegrityArtifact] = [], signals: [IntegritySignal] = [],
    unavailableSources: [String] = [], checkedSources: [String] = []
  ) {
    self.version = Self.currentVersion
    self.capturedAt = capturedAt
    self.states = states
    self.artifacts = Dictionary(grouping: artifacts, by: \.stableKey).values.map {
      Self.consolidated($0)
    }.sorted { $0.stableKey < $1.stableKey }
    self.signals = signals
    self.unavailableSources = unavailableSources.sorted()
    self.checkedSources = checkedSources.sorted()
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

public struct IntegrityCoverageGap: Equatable, Identifiable, Sendable {
  public var id: String
  public var title: String
  public var critical: Bool

  public init(id: String, title: String, critical: Bool) {
    self.id = id
    self.title = title
    self.critical = critical
  }
}

public struct IntegrityCoverageReport: Equatable, Sendable {
  public var checkedCount: Int
  public var expectedCount: Int
  public var gaps: [IntegrityCoverageGap]

  public var criticalGaps: [IntegrityCoverageGap] { gaps.filter(\.critical) }
  public var isSuitableForBaseline: Bool { criticalGaps.isEmpty }
}

extension SystemIntegritySnapshot {
  /// Keeps the previously supported sources monitored while a user reviews newly introduced
  /// collectors. This avoids treating an application update itself as dozens of new artifacts.
  public func comparisonSnapshot(for baseline: SystemIntegritySnapshot) -> SystemIntegritySnapshot {
    guard baseline.version < Self.currentVersion else { return self }
    let legacyKinds: Set<IntegrityArtifact.Kind> = [
      .configurationProfile, .managedPreference, .systemExtension, .launchAgent, .launchDaemon,
      .privilegedHelper,
    ]
    return SystemIntegritySnapshot(
      capturedAt: capturedAt, states: states,
      artifacts: artifacts.filter { legacyKinds.contains($0.kind) }, signals: signals,
      unavailableSources: unavailableSources, checkedSources: checkedSources ?? [])
  }

  public var coverageReport: IntegrityCoverageReport {
    let checked = Set(checkedSources ?? [])
    let unavailable = Set(unavailableSources)
    let gaps = Self.coverageSources.compactMap { source -> IntegrityCoverageGap? in
      guard !checked.contains(source.id) || unavailable.contains(source.id) else { return nil }
      return source
    }
    return IntegrityCoverageReport(
      checkedCount: Self.coverageSources.count - gaps.count,
      expectedCount: Self.coverageSources.count, gaps: gaps)
  }

  private static let coverageSources: [IntegrityCoverageGap] = [
    .init(id: "security.firewall", title: "Firewall", critical: true),
    .init(id: "security.filevault", title: "FileVault", critical: true),
    .init(id: "security.gatekeeper", title: "Gatekeeper", critical: true),
    .init(id: "security.sip", title: "Systemintegritätsschutz", critical: true),
    .init(id: "mdm.enrollment", title: "MDM-Anmeldung", critical: true),
    .init(id: "identity.admin_members", title: "Lokale Administratoren", critical: true),
    .init(id: "identity.local_users", title: "Lokale Benutzer", critical: true),
    .init(id: "artifacts.configurationProfile", title: "Konfigurationsprofile", critical: true),
    .init(id: "artifacts.launchAgent", title: "LaunchAgents", critical: true),
    .init(id: "artifacts.launchDaemon", title: "LaunchDaemons", critical: true),
    .init(id: "artifacts.privilegedHelper", title: "Privilegierte Hilfsprogramme", critical: true),
    .init(id: "middleai.bundle", title: "MiddleAI-Programmdatei", critical: true),
    .init(id: "artifacts.managedPreference", title: "Verwaltete Einstellungen", critical: false),
    .init(id: "artifacts.systemExtension", title: "Systemerweiterungen", critical: false),
    .init(id: "artifacts.systemCertificate", title: "Systemzertifikate", critical: false),
    .init(
      id: "artifacts.rootCertificate", title: "Zertifikat-Vertrauensstellungen", critical: true),
    .init(id: "security.logs", title: "Lokale Sicherheitslogs", critical: false),
    .init(id: "defender.health", title: "Microsoft Defender", critical: false),
    .init(id: "artifacts.loginItem", title: "Anmeldeobjekte", critical: false),
    .init(id: "artifacts.scheduledTask", title: "Geplante Tasks", critical: true),
    .init(id: "artifacts.authorizedKey", title: "Autorisierte SSH-Schlüssel", critical: true),
    .init(id: "artifacts.shellStartup", title: "Shell-Startdateien", critical: false),
  ]
}

public enum IntegrityFindingState: String, Codable, CaseIterable, Sendable {
  case new
  case ongoing
  case escalated
  case acknowledged
  case resolved

  public var title: String {
    switch self {
    case .new: return "Neu"
    case .ongoing: return "Anhaltend"
    case .escalated: return "Eskaliert"
    case .acknowledged: return "Geprüft"
    case .resolved: return "Behoben"
    }
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
  public var subjectID: String?
  public var state: IntegrityFindingState?
  public var firstDetectedAt: Date?
  public var resolvedAt: Date?
  public var acknowledgedAt: Date?
  public var acknowledgementNote: String?
  public var source: IntegrityFindingSource?

  public init(
    detectedAt: Date = Date(), severity: IntegritySeverity, category: IntegrityCategory,
    title: String, detail: String, evidence: String = "", occurrenceCount: Int = 1,
    localExplanation: String? = nil, simulated: Bool = false, identityMaterial: String? = nil,
    subjectMaterial: String? = nil, source: IntegrityFindingSource? = nil
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
    self.subjectID = IntegrityHash.sha256(
      subjectMaterial ?? "\(category.rawValue)|\(self.title)")
    self.state = .new
    self.firstDetectedAt = detectedAt
    self.resolvedAt = nil
    self.acknowledgedAt = nil
    self.acknowledgementNote = nil
    self.source = source
  }

  public var lifecycleState: IntegrityFindingState { state ?? .new }
  public var effectiveSubjectID: String { subjectID ?? id }
  public var isActive: Bool { lifecycleState != .resolved }
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
      case (let old?, let new?) where Self.artifactContentChanged(old, new):
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
        evidence: "Interne Simulation · keine Systemeinstellung wurde verändert", simulated: true,
        subjectMaterial: "simulation-info")
    case .warning:
      return IntegrityFinding(
        detectedAt: now, severity: .warning, category: .persistence,
        title: "Test: Neuer LaunchAgent",
        detail: "Ein neuer signierter Autostarteintrag weicht vom bestätigten Sollzustand ab.",
        evidence: "Interne Simulation · keine Datei wurde angelegt", simulated: true,
        subjectMaterial: "simulation-warning")
    case .critical:
      return IntegrityFinding(
        detectedAt: now, severity: .critical, category: .securityConfiguration,
        title: "Test: Firewall deaktiviert",
        detail:
          "Eine zentrale Schutzfunktion wurde gegenüber dem bestätigten Sollzustand abgeschwächt.",
        evidence: "Interne Simulation · die Firewall blieb unverändert", simulated: true,
        subjectMaterial: "simulation-critical")
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
      identityMaterial: "state|\(key)|\(old)|\(new)", subjectMaterial: "state|\(key)",
      source: Self.source(forStateKey: key))
  }

  private func artifactAdded(_ artifact: IntegrityArtifact, now: Date) -> IntegrityFinding {
    let metadata = Self.artifactMetadata(artifact.kind)
    let unsignedCritical = artifact.signed == false && artifact.kind != .configurationProfile
    let severity: IntegritySeverity =
      unsignedCritical
      ? .critical
      : max(
        artifact.risk ?? metadata.severity, metadata.severity)
    return IntegrityFinding(
      detectedAt: now, severity: severity, category: metadata.category,
      title: "Neu: \(artifact.identifier)",
      detail: unsignedCritical
        ? "Ein nicht gültig signierter Persistenz- oder Systemeintrag wurde hinzugefügt."
        : "Ein neuer \(metadata.singular) weicht vom bestätigten Sollzustand ab.",
      evidence: Self.artifactEvidence(artifact),
      identityMaterial: "artifact-added|\(artifact.stableKey)|\(artifact.digest)",
      subjectMaterial: "artifact|\(artifact.stableKey)", source: artifact.source)
  }

  private func artifactRemoved(_ artifact: IntegrityArtifact, now: Date) -> IntegrityFinding {
    let metadata = Self.artifactMetadata(artifact.kind)
    let severity = max(artifact.risk ?? .warning, .warning)
    return IntegrityFinding(
      detectedAt: now, severity: severity, category: metadata.category,
      title: "Entfernt: \(artifact.identifier)",
      detail: "Ein zuvor bestätigter \(metadata.singular) ist nicht mehr vorhanden.",
      evidence: Self.artifactEvidence(artifact),
      identityMaterial: "artifact-removed|\(artifact.stableKey)|\(artifact.digest)",
      subjectMaterial: "artifact|\(artifact.stableKey)", source: artifact.source)
  }

  private func artifactChanged(
    old: IntegrityArtifact, new: IntegrityArtifact, now: Date
  ) -> IntegrityFinding {
    let metadata = Self.artifactMetadata(new.kind)
    let signatureRegressed = old.signed != false && new.signed == false
    return IntegrityFinding(
      detectedAt: now,
      severity: signatureRegressed ? .critical : max(new.risk ?? old.risk ?? .warning, .warning),
      category: metadata.category, title: "Verändert: \(new.identifier)",
      detail: signatureRegressed
        ? "Die Signatur eines zuvor bestätigten Eintrags ist nicht mehr gültig."
        : "Der Inhalt eines bestätigten \(metadata.singular) wurde verändert.",
      evidence: Self.artifactEvidence(new),
      identityMaterial: "artifact-changed|\(new.stableKey)|\(old.digest)|\(new.digest)",
      subjectMaterial: "artifact|\(new.stableKey)", source: new.source ?? old.source)
  }

  private func finding(for signal: IntegritySignal, now: Date) -> IntegrityFinding {
    IntegrityFinding(
      detectedAt: now, severity: signal.severity, category: signal.category,
      title: signal.summary, detail: "Das Ereignis wurde in lokalen macOS-Daten erkannt.",
      evidence: signal.count > 1 ? "\(signal.count) gleichartige Ereignisse" : "Ein Ereignis",
      occurrenceCount: signal.count,
      identityMaterial: "signal|\(signal.identifier)|\(signal.summary)",
      subjectMaterial: "signal|\(signal.identifier)", source: signal.source)
  }

  private static func sortFindings(_ lhs: IntegrityFinding, _ rhs: IntegrityFinding) -> Bool {
    if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
    return lhs.detectedAt > rhs.detectedAt
  }

  private static let securityDegradationKeys: Set<String> = [
    "security.firewall", "security.filevault", "security.gatekeeper", "security.sip",
    "security.stealth_mode", "defender.healthy", "defender.licensed",
    "defender.installed", "defender.real_time_protection", "defender.full_disk_access",
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
    "defender.installed": (
      .critical, .securityConfiguration, "Microsoft Defender Installation verändert"
    ),
    "defender.healthy": (.warning, .securityConfiguration, "Microsoft Defender Zustand verändert"),
    "defender.licensed": (
      .critical, .securityConfiguration, "Microsoft Defender Lizenzstatus verändert"
    ),
    "defender.real_time_protection": (
      .critical, .securityConfiguration, "Microsoft Defender Echtzeitschutz verändert"
    ),
    "defender.network_protection": (
      .warning, .securityConfiguration, "Microsoft Defender Netzwerkschutz verändert"
    ),
    "defender.definitions": (
      .warning, .securityConfiguration, "Microsoft Defender Definitionen verändert"
    ),
    "defender.full_disk_access": (
      .critical, .securityConfiguration, "Microsoft Defender Festplattenzugriff verändert"
    ),
    "defender.tamper_protection": (
      .critical, .securityConfiguration, "Microsoft Defender Manipulationsschutz verändert"
    ),
    "defender.passive_mode": (
      .warning, .securityConfiguration, "Microsoft Defender Betriebsmodus verändert"
    ),
  ]

  private static func artifactMetadata(_ kind: IntegrityArtifact.Kind) -> (
    severity: IntegritySeverity, category: IntegrityCategory, singular: String
  ) {
    switch kind {
    case .configurationProfile: return (.warning, .deviceManagement, "Konfigurationsprofil")
    case .managedPreference: return (.warning, .deviceManagement, "verwaltete Einstellung")
    case .systemExtension: return (.warning, .securityConfiguration, "Systemerweiterung")
    case .systemCertificate: return (.warning, .certificates, "Systemzertifikat")
    case .launchAgent: return (.warning, .persistence, "LaunchAgent")
    case .launchDaemon: return (.warning, .persistence, "LaunchDaemon")
    case .privilegedHelper: return (.critical, .persistence, "privilegierter Hilfsprozess")
    case .rootCertificate: return (.critical, .certificates, "Root-Zertifikat")
    case .loginItem: return (.warning, .persistence, "Anmeldeobjekt")
    case .scheduledTask: return (.warning, .persistence, "geplanter Task")
    case .authorizedKey: return (.critical, .persistence, "autorisierter SSH-Schlüssel")
    case .shellStartup: return (.warning, .persistence, "Shell-Startdatei")
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

  private static func artifactContentChanged(
    _ old: IntegrityArtifact, _ new: IntegrityArtifact
  ) -> Bool {
    old.digest != new.digest || old.teamIdentifier != new.teamIdentifier
      || old.signed != new.signed
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

  private static func source(forStateKey key: String) -> IntegrityFindingSource? {
    let privacy = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
    switch key {
    case "security.firewall", "network.proxy", "network.dns":
      return IntegrityFindingSource(
        kind: .systemSettings, title: "Netzwerkeinstellungen",
        locator: "x-apple.systempreferences:com.apple.Network-Settings.extension",
        collectorID: key)
    case "security.filevault", "security.gatekeeper", "security.sip":
      return IntegrityFindingSource(
        kind: .systemSettings, title: "Datenschutz & Sicherheit", locator: privacy,
        collectorID: key)
    case "security.remote_login", "security.remote_management":
      return IntegrityFindingSource(
        kind: .systemSettings, title: "Freigaben",
        locator: "x-apple.systempreferences:com.apple.Sharing-Settings.extension",
        collectorID: key)
    case "mdm.enrollment", "mdm.server":
      return IntegrityFindingSource(
        kind: .profile, title: "Geräteverwaltung",
        locator: "x-apple.systempreferences:com.apple.Profiles-Settings.extension",
        collectorID: key)
    case "identity.admin_members", "identity.local_users":
      return IntegrityFindingSource(
        kind: .systemSettings, title: "Benutzer & Gruppen",
        locator: "x-apple.systempreferences:com.apple.Users-Groups-Settings.extension",
        collectorID: key)
    case "certificates.system_roots":
      return IntegrityFindingSource(
        kind: .keychain, title: "Schlüsselbundverwaltung",
        locator: "/System/Applications/Utilities/Keychain Access.app", collectorID: key)
    case "middleai.bundle":
      return IntegrityFindingSource(
        kind: .file, title: "MiddleAI.app", locator: "/Applications/MiddleAI.app",
        collectorID: key)
    case _ where key.hasPrefix("defender."):
      return IntegrityFindingSource(
        kind: .application, title: "Microsoft Defender",
        locator: "/Applications/Microsoft Defender.app", collectorID: "defender.health")
    default: return nil
    }
  }
}

public enum IntegrityHistoryStatus: Equatable, Sendable {
  case empty
  case valid(Int)
  case corrupted
}

public actor SystemIntegrityStore {
  private struct BaselineDocument: Codable {
    var version: Int
    var snapshot: SystemIntegritySnapshot
    var hash: String?
    var authenticationCode: String?
  }
  private struct HistoryRecord: Codable {
    var finding: IntegrityFinding
    var previousHash: String?
    var hash: String?
    var previousAuthenticationCode: String?
    var authenticationCode: String?
  }
  private struct HistoryDocument: Codable {
    var version: Int
    var records: [HistoryRecord]
  }

  public static var defaultDirectory: URL {
    ConfigLoader.defaultDirectory.appendingPathComponent("system-integrity", isDirectory: true)
  }

  private let directory: URL
  private let providedAuthenticationKey: Data?
  private var cachedAuthenticationKey: Data?
  private var historyStatus: IntegrityHistoryStatus = .empty

  public init(directory: URL = defaultDirectory, authenticationKey: Data? = nil) {
    self.directory = directory
    self.providedAuthenticationKey = authenticationKey
  }

  public func baseline() throws -> SystemIntegritySnapshot? {
    guard let document = try decodeIfPresent(BaselineDocument.self, from: baselineURL) else {
      return nil
    }
    let valid: Bool
    if document.version >= 2, let code = document.authenticationCode {
      valid =
        code
        == Self.authenticationCode(
          for: Self.encoded(document.snapshot), domain: "baseline-v2", key: try authenticationKey())
    } else {
      valid = document.hash == Self.legacyBaselineHash(document.snapshot)
    }
    guard valid else {
      throw MiddleAIError.configuration("Die lokale Integritäts-Baseline wurde verändert.")
    }
    // A locked Keychain must not make a previously valid baseline unreadable. Migration is retried
    // on the next read; creating or replacing a baseline still fails closed when HMAC is unavailable.
    if document.version < 2 { try? saveBaseline(document.snapshot) }
    return document.snapshot
  }

  public func saveBaseline(_ snapshot: SystemIntegritySnapshot) throws {
    let code = Self.authenticationCode(
      for: Self.encoded(snapshot), domain: "baseline-v2", key: try authenticationKey())
    try secureWrite(
      BaselineDocument(version: 2, snapshot: snapshot, hash: nil, authenticationCode: code),
      to: baselineURL)
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
    let valid: Bool
    if document.version >= 2 {
      valid = Self.validAuthenticated(document.records, key: try authenticationKey())
    } else {
      valid = Self.validLegacy(document.records)
    }
    guard valid else {
      historyStatus = .corrupted
      throw MiddleAIError.configuration(
        "Die lokale Integritätshistorie konnte kryptografisch nicht bestätigt werden.")
    }
    historyStatus = .valid(document.records.count)
    let findings = document.records.map(\.finding).sorted { $0.detectedAt > $1.detectedAt }
    if document.version < 2 { try? saveHistory(findings) }
    return findings
  }

  @discardableResult
  public func reconcile(
    _ current: [IntegrityFinding], retentionDays: Int, now: Date = Date(),
    preserveSubjectIDs: Set<String> = []
  ) throws -> [IntegrityFinding] {
    var existing = try findings()
    let current = current.filter { !$0.simulated }
    let activeCurrentIDs = Set(current.map(\.id))
    let activeCurrentSubjects = Set(current.map(\.effectiveSubjectID))

    for index in existing.indices
    where existing[index].isActive
      && !activeCurrentIDs.contains(existing[index].id)
      && !activeCurrentSubjects.contains(existing[index].effectiveSubjectID)
      && !preserveSubjectIDs.contains(existing[index].effectiveSubjectID)
    {
      existing[index].state = .resolved
      existing[index].resolvedAt = now
    }

    for var finding in current {
      if let index = existing.firstIndex(where: { $0.id == finding.id }) {
        let wasResolved = existing[index].lifecycleState == .resolved
        existing[index].detectedAt = finding.detectedAt
        existing[index].occurrenceCount =
          wasResolved
          ? finding.occurrenceCount : existing[index].occurrenceCount + finding.occurrenceCount
        existing[index].severity = max(existing[index].severity, finding.severity)
        existing[index].localExplanation =
          finding.localExplanation ?? existing[index].localExplanation
        existing[index].source = finding.source ?? existing[index].source
        existing[index].resolvedAt = nil
        if wasResolved {
          existing[index].state = .new
          existing[index].firstDetectedAt = now
          existing[index].acknowledgedAt = nil
          existing[index].acknowledgementNote = nil
        } else if existing[index].lifecycleState != .acknowledged {
          existing[index].state = .ongoing
        }
      } else if let index = existing.firstIndex(where: {
        $0.isActive && $0.effectiveSubjectID == finding.effectiveSubjectID
      }) {
        let previousSeverity = existing[index].severity
        existing[index].state = .resolved
        existing[index].resolvedAt = now
        finding.state = finding.severity > previousSeverity ? .escalated : .new
        finding.firstDetectedAt = now
        existing.append(finding)
      } else {
        finding.state = .new
        finding.firstDetectedAt = now
        existing.append(finding)
      }
    }
    if retentionDays > 0,
      let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: now)
    {
      existing.removeAll {
        ($0.resolvedAt ?? $0.detectedAt) < cutoff && $0.lifecycleState == .resolved
      }
    }
    existing.sort { $0.detectedAt < $1.detectedAt }
    if existing.count > 500 { existing.removeFirst(existing.count - 500) }
    try saveHistory(existing)
    return existing.sorted { $0.detectedAt > $1.detectedAt }
  }

  /// Compatibility helper for callers that only add findings. New scans should use `reconcile`.
  public func append(_ additions: [IntegrityFinding], retentionDays: Int, now: Date = Date()) throws
  {
    _ = try reconcile(additions, retentionDays: retentionDays, now: now)
  }

  @discardableResult
  public func acknowledge(
    _ id: String, note: String? = nil, now: Date = Date()
  ) throws -> [IntegrityFinding] {
    var existing = try findings()
    guard let index = existing.firstIndex(where: { $0.id == id && $0.isActive }) else {
      return existing
    }
    existing[index].state = .acknowledged
    existing[index].acknowledgedAt = now
    let cleaned = note?.trimmingCharacters(in: .whitespacesAndNewlines)
    existing[index].acknowledgementNote = cleaned.map { String($0.prefix(300)) }
    try saveHistory(existing)
    return existing.sorted { $0.detectedAt > $1.detectedAt }
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

  private func saveHistory(_ findings: [IntegrityFinding]) throws {
    let records = Self.authenticatedRecords(for: findings, key: try authenticationKey())
    try secureWrite(HistoryDocument(version: 2, records: records), to: historyURL)
    historyStatus = .valid(records.count)
  }

  private func authenticationKey() throws -> Data {
    if let providedAuthenticationKey { return providedAuthenticationKey }
    if let cachedAuthenticationKey { return cachedAuthenticationKey }
    let service = "de.middleai.system-integrity"
    let account = "local-authentication-key"
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let readStatus = SecItemCopyMatching(query as CFDictionary, &item)
    if readStatus == errSecSuccess, let data = item as? Data, data.count >= 32 {
      cachedAuthenticationKey = data
      return data
    }
    guard readStatus == errSecItemNotFound else {
      throw MiddleAIError.configuration(
        "Der lokale Schlüssel für den Systemwächter ist nicht verfügbar (\(readStatus)).")
    }
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw MiddleAIError.configuration(
        "Der lokale Systemwächter-Schlüssel konnte nicht erzeugt werden.")
    }
    let key = Data(bytes)
    var add = query
    add.removeValue(forKey: kSecReturnData as String)
    add.removeValue(forKey: kSecMatchLimit as String)
    add[kSecValueData as String] = key
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let addStatus = SecItemAdd(add as CFDictionary, nil)
    guard addStatus == errSecSuccess || addStatus == errSecDuplicateItem else {
      throw MiddleAIError.configuration(
        "Der lokale Systemwächter-Schlüssel konnte nicht gespeichert werden (\(addStatus)).")
    }
    if addStatus == errSecDuplicateItem {
      var retry: CFTypeRef?
      guard SecItemCopyMatching(query as CFDictionary, &retry) == errSecSuccess,
        let stored = retry as? Data
      else { throw MiddleAIError.configuration("Der Systemwächter-Schlüssel ist nicht lesbar.") }
      cachedAuthenticationKey = stored
      return stored
    }
    cachedAuthenticationKey = key
    return key
  }

  private static func authenticatedRecords(
    for findings: [IntegrityFinding], key: Data
  ) -> [HistoryRecord] {
    var previous = "middleai-integrity-history-v2"
    return findings.map { finding in
      let material = canonical(finding)
      let code = authenticationCode(
        for: Data("\(previous)|\(material)".utf8), domain: "history-v2", key: key)
      defer { previous = code }
      return HistoryRecord(
        finding: finding, previousHash: nil, hash: nil,
        previousAuthenticationCode: previous, authenticationCode: code)
    }
  }

  private static func validAuthenticated(_ records: [HistoryRecord], key: Data) -> Bool {
    var previous = "middleai-integrity-history-v2"
    for record in records {
      let expected = authenticationCode(
        for: Data("\(previous)|\(canonical(record.finding))".utf8), domain: "history-v2",
        key: key)
      guard record.previousAuthenticationCode == previous,
        record.authenticationCode == expected
      else { return false }
      previous = expected
    }
    return true
  }

  private static func validLegacy(_ records: [HistoryRecord]) -> Bool {
    var previous = "middleai-integrity-history-v1"
    for record in records {
      guard let hash = record.hash, record.previousHash == previous,
        hash == IntegrityHash.sha256("\(previous)|\(legacyCanonical(record.finding))")
      else { return false }
      previous = hash
    }
    return true
  }

  private static func legacyCanonical(_ finding: IntegrityFinding) -> String {
    "\(finding.id)|\(Int(finding.detectedAt.timeIntervalSince1970))|\(finding.severity.rawValue)|\(finding.category.rawValue)|\(finding.title)|\(finding.detail)|\(finding.evidence)|\(finding.occurrenceCount)|\(finding.localExplanation ?? "")"
  }

  private static func canonical(_ finding: IntegrityFinding) -> String {
    encoded(finding).base64EncodedString()
  }

  private static func encoded<T: Encodable>(_ value: T) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return (try? encoder.encode(value)) ?? Data()
  }

  private static func authenticationCode(for data: Data, domain: String, key: Data) -> String {
    let material = Data("middleai-integrity-\(domain)|".utf8) + data
    return HMAC<SHA256>.authenticationCode(
      for: material, using: SymmetricKey(data: key)
    ).map { String(format: "%02x", $0) }.joined()
  }

  private static func legacyBaselineHash(_ snapshot: SystemIntegritySnapshot) -> String {
    IntegrityHash.sha256(Data("middleai-integrity-baseline-v1|".utf8) + encoded(snapshot))
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
