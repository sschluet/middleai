import Foundation
import XCTest

@testable import MiddleAICore

final class SystemIntegrityMonitorTests: XCTestCase {
  func testDetectsSecurityDegradationAndUnsignedPersistence() {
    let baseline = SystemIntegritySnapshot(
      states: ["security.firewall": "enabled", "identity.admin_members": "admin-a"],
      artifacts: [
        IntegrityArtifact(
          kind: .configurationProfile, identifier: "com.example.policy", digest: "old")
      ])
    let current = SystemIntegritySnapshot(
      states: ["security.firewall": "disabled", "identity.admin_members": "admin-b"],
      artifacts: [
        IntegrityArtifact(
          kind: .configurationProfile, identifier: "com.example.policy", digest: "new"),
        IntegrityArtifact(
          kind: .launchDaemon, identifier: "com.example.unknown", digest: "binary",
          signed: false),
      ])

    let result = SystemIntegrityRuleEngine().evaluate(baseline: baseline, current: current)

    XCTAssertTrue(result.baselineAvailable)
    XCTAssertEqual(result.findings.filter { $0.severity == .critical }.count, 3)
    XCTAssertTrue(result.findings.contains { $0.title == "Firewall-Zustand verändert" })
    XCTAssertTrue(result.findings.contains { $0.title == "Lokale Administratoren verändert" })
    XCTAssertTrue(result.findings.contains { $0.title.contains("com.example.unknown") })
    XCTAssertTrue(result.findings.contains { $0.title.contains("com.example.policy") })
  }

  func testUnavailableSourceNeverLooksLikeRemoval() {
    let baseline = SystemIntegritySnapshot(
      artifacts: [
        IntegrityArtifact(
          kind: .launchDaemon, identifier: "com.example.daemon", digest: "known")
      ])
    let current = SystemIntegritySnapshot(unavailableSources: ["artifacts.launchDaemon"])

    let result = SystemIntegrityRuleEngine().evaluate(baseline: baseline, current: current)

    XCTAssertTrue(result.findings.isEmpty)
  }

  func testDuplicateArtifactIdentifiersAreConsolidatedSafely() {
    let snapshot = SystemIntegritySnapshot(
      artifacts: [
        IntegrityArtifact(
          kind: .systemExtension, identifier: "com.example.extension", digest: "v1"),
        IntegrityArtifact(
          kind: .systemExtension, identifier: "com.example.extension", digest: "v2"),
      ])

    XCTAssertEqual(snapshot.artifacts.count, 1)
    XCTAssertNotEqual(snapshot.artifacts[0].digest, "v1")
    XCTAssertNotEqual(snapshot.artifacts[0].digest, "v2")
  }

  func testStoreDetectsBaselineAndHistoryModification() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "middleai-integrity-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SystemIntegrityStore(
      directory: directory, authenticationKey: Data(repeating: 0x42, count: 32))
    let snapshot = SystemIntegritySnapshot(states: ["security.firewall": "enabled"])
    try await store.saveBaseline(snapshot)
    let restoredBaseline = try await store.baseline()
    XCTAssertEqual(restoredBaseline?.states["security.firewall"], "enabled")

    let baselineURL = directory.appendingPathComponent("baseline.json")
    var baselineText = try String(contentsOf: baselineURL, encoding: .utf8)
    baselineText = baselineText.replacingOccurrences(of: "enabled", with: "disabled")
    try baselineText.write(to: baselineURL, atomically: true, encoding: .utf8)
    do {
      _ = try await store.baseline()
      XCTFail("Manipulierte Baseline wurde akzeptiert")
    } catch {}

    let finding = IntegrityFinding(
      severity: .warning, category: .network, title: "Proxy verändert", detail: "Test")
    try await store.append([finding], retentionDays: 30)
    let historyURL = directory.appendingPathComponent("findings.json")
    var historyText = try String(contentsOf: historyURL, encoding: .utf8)
    historyText = historyText.replacingOccurrences(of: "Proxy verändert", with: "Kein Befund")
    try historyText.write(to: historyURL, atomically: true, encoding: .utf8)
    do {
      _ = try await store.findings()
      XCTFail("Manipulierte Historie wurde akzeptiert")
    } catch {}
  }

  func testCoverageBlocksBaselineWhenCriticalSourceIsMissing() {
    let snapshot = SystemIntegritySnapshot(
      unavailableSources: ["security.firewall"], checkedSources: ["security.filevault"])

    XCTAssertFalse(snapshot.coverageReport.isSuitableForBaseline)
    XCTAssertTrue(snapshot.coverageReport.criticalGaps.contains { $0.id == "security.firewall" })
  }

  func testFindingLifecycleAcknowledgesResolvesAndReopens() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "middleai-integrity-lifecycle-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SystemIntegrityStore(
      directory: directory, authenticationKey: Data(repeating: 0x24, count: 32))
    let finding = IntegrityFinding(
      severity: .warning, category: .persistence, title: "Neuer Autostart",
      detail: "Test", subjectMaterial: "autostart")

    var history = try await store.reconcile([finding], retentionDays: 30)
    XCTAssertEqual(history.first?.lifecycleState, .new)
    history = try await store.acknowledge(finding.id)
    XCTAssertEqual(history.first?.lifecycleState, .acknowledged)
    history = try await store.reconcile([], retentionDays: 30)
    XCTAssertEqual(history.first?.lifecycleState, .resolved)
    history = try await store.reconcile([finding], retentionDays: 30)
    XCTAssertEqual(history.first?.lifecycleState, .new)
  }

  func testSourceMetadataDoesNotCreateFalseArtifactChange() {
    let old = IntegrityArtifact(
      kind: .launchAgent, identifier: "com.example.agent", digest: "same")
    let new = IntegrityArtifact(
      kind: .launchAgent, identifier: "com.example.agent", digest: "same",
      source: IntegrityFindingSource(kind: .file, title: "Agent", locator: "/Library/agent"))

    let result = SystemIntegrityRuleEngine().evaluate(
      baseline: SystemIntegritySnapshot(artifacts: [old]),
      current: SystemIntegritySnapshot(artifacts: [new]))

    XCTAssertTrue(result.findings.isEmpty)
  }
}
