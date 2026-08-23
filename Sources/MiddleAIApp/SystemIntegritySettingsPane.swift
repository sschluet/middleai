import MiddleAICore
import SwiftUI

struct SystemIntegritySettingsPane: View {
  @ObservedObject var state: AppState
  @ObservedObject var monitor: SystemIntegrityMonitorController
  @State private var confirmsBaselineReplacement = false
  @State private var confirmsBaselineRemoval = false
  @State private var confirmsHistoryDeletion = false
  @State private var findingFilter = "active"

  var body: some View {
    VStack(spacing: 16) {
      statusCard
      baselineCard
      scopeCard
      alertsCard
      localIntelligenceCard
      testsCard
      findingsCard
      limitsCard
    }
    .confirmationDialog(
      "Aktuellen Zustand als neue Baseline übernehmen?",
      isPresented: $confirmsBaselineReplacement
    ) {
      Button("Baseline ersetzen") { monitor.replaceBaselineWithPendingSnapshot() }
      Button("Abbrechen", role: .cancel) {}
    } message: {
      Text(
        "Prüfe offene Befunde vorher sorgfältig. Bestätigte Abweichungen gelten anschließend als vertrauenswürdig."
      )
    }
    .confirmationDialog(
      "Baseline entfernen?", isPresented: $confirmsBaselineRemoval
    ) {
      Button("Baseline entfernen", role: .destructive) { monitor.removeBaseline() }
      Button("Abbrechen", role: .cancel) {}
    } message: {
      Text("Bis zu einer neuen Bestätigung kann MiddleAI Änderungen nicht bewerten.")
    }
    .confirmationDialog(
      "Lokale Befundhistorie löschen?", isPresented: $confirmsHistoryDeletion
    ) {
      Button("Historie löschen", role: .destructive) { monitor.clearHistory() }
      Button("Abbrechen", role: .cancel) {}
    }
  }

  private var statusCard: some View {
    SettingsCard(
      title: "Lokaler Systemwächter",
      subtitle: "Erkennt sicherheitsrelevante Abweichungen von deinem bestätigten Mac-Zustand",
      symbol: "shield.checkered"
    ) {
      Toggle("Systemwächter aktivieren", isOn: $state.config.securityMonitor.enabled)
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: statusSymbol)
          .foregroundStyle(statusColor)
        VStack(alignment: .leading, spacing: 4) {
          Text(monitor.status).font(.callout.weight(.medium))
          if let lastScan = monitor.lastScan {
            Text("Letzte Prüfung: \(lastScan.formatted(date: .abbreviated, time: .standard))")
              .font(.caption).foregroundStyle(.secondary)
          }
          Text(monitor.notificationStatus).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        if monitor.scanRunning { ProgressView().controlSize(.small) }
      }
      HStack {
        Button("Einstellungen anwenden") { state.saveSystemIntegritySettings() }
          .buttonStyle(.borderedProminent)
        Button("Jetzt prüfen") { monitor.runNow() }
          .disabled(monitor.scanRunning || !state.config.securityMonitor.enabled)
        Spacer()
      }
    }
  }

  private var baselineCard: some View {
    SettingsCard(
      title: "Vertrauenswürdige Baseline",
      subtitle:
        "MiddleAI meldet spätere Änderungen gegenüber diesem ausdrücklich bestätigten Zustand",
      symbol: "checkmark.seal"
    ) {
      Label(
        monitor.baselineAvailable ? "Baseline vorhanden" : "Noch keine Baseline bestätigt",
        systemImage: monitor.baselineAvailable ? "checkmark.circle.fill" : "exclamationmark.circle"
      )
      .foregroundStyle(monitor.baselineAvailable ? .green : .orange)
      Text(
        "Erstelle die Baseline nur, wenn der Mac gerade in einem bekannten und vertrauenswürdigen Zustand ist. MiddleAI speichert ausschließlich normalisierte Zustände, Fingerabdrücke und technische Kennungen lokal unter ~/.middleai/system-integrity."
      )
      .font(.caption).foregroundStyle(.secondary)
      if let snapshot = monitor.pendingSnapshot {
        Label(
          snapshot.coverageReport.isSuitableForBaseline
            ? "Die Prüfung ist vollständig. Bestätige den Zustand erst, wenn er vertrauenswürdig ist."
            : "Die Baseline kann nicht bestätigt werden, solange wichtige Quellen fehlen.",
          systemImage: snapshot.coverageReport.isSuitableForBaseline
            ? "checkmark.shield" : "exclamationmark.shield"
        )
        .font(.caption).foregroundStyle(
          snapshot.coverageReport.isSuitableForBaseline ? .green : .orange)
        coverageView(snapshot.coverageReport)
      } else if let coverage = monitor.coverageReport {
        coverageView(coverage)
      }
      HStack {
        if let snapshot = monitor.pendingSnapshot, snapshot.coverageReport.isSuitableForBaseline {
          Button(
            monitor.baselineAvailable
              ? "Geprüfte Baseline übernehmen" : "Geprüfte Baseline bestätigen"
          ) {
            confirmsBaselineReplacement = true
          }
          .buttonStyle(.borderedProminent)
        }
        if monitor.baselineAvailable {
          Button("Neuen Zustand prüfen") { monitor.captureBaseline() }
          Button("Baseline entfernen", role: .destructive) { confirmsBaselineRemoval = true }
        } else {
          Button("Ausgangszustand prüfen") { monitor.captureBaseline() }
        }
        Spacer()
      }
    }
  }

  private var scopeCard: some View {
    SettingsCard(
      title: "Prüfumfang",
      subtitle: "Wähle die lokalen Bereiche, deren Abweichungen als Befund erscheinen",
      symbol: "scope"
    ) {
      ForEach(IntegrityCategory.allCases, id: \.rawValue) { category in
        Toggle(
          category.title,
          isOn: Binding(
            get: { state.config.securityMonitor.categories.contains(category.rawValue) },
            set: { enabled in updateCategory(category, enabled: enabled) }))
      }
      Divider()
      Stepper(
        "Regelmäßig alle \(state.config.securityMonitor.intervalMinutes) Minuten prüfen",
        value: $state.config.securityMonitor.intervalMinutes, in: 10...1_440, step: 5)
      Text(
        "Zusätzlich reagiert MiddleAI zeitnah auf Änderungen an Autostart-, SSH-, Shell- und verwalteten Einstellungsdateien. Die regelmäßige Prüfung umfasst außerdem Anmeldeobjekte, Crontab, Zertifikate, Profile, Microsoft Defender und ausgewählte lokale Sicherheitslogs. macOS darf Hintergrundprüfungen zur Schonung von Akku und Leistung verschieben."
      )
      .font(.caption).foregroundStyle(.secondary)
    }
  }

  private var alertsCard: some View {
    SettingsCard(
      title: "Warnungen",
      subtitle: "Begrenzt Benachrichtigungen und verhindert störende Wiederholungen",
      symbol: "bell.badge"
    ) {
      Picker(
        "macOS-Benachrichtigung ab",
        selection: $state.config.securityMonitor.notificationMinimumSeverity
      ) {
        severityOptions
      }
      Toggle("Kritische Befunde lokal vorlesen", isOn: $state.config.securityMonitor.voiceEnabled)
      if state.config.securityMonitor.voiceEnabled {
        Picker(
          "Vorlesen ab", selection: $state.config.securityMonitor.voiceMinimumSeverity
        ) {
          severityOptions
        }
        Toggle("Ruhezeit verwenden", isOn: $state.config.securityMonitor.quietHoursEnabled)
        if state.config.securityMonitor.quietHoursEnabled {
          HStack {
            Stepper(
              "Von \(state.config.securityMonitor.quietHoursStart):00 Uhr",
              value: $state.config.securityMonitor.quietHoursStart, in: 0...23)
            Stepper(
              "bis \(state.config.securityMonitor.quietHoursEnd):00 Uhr",
              value: $state.config.securityMonitor.quietHoursEnd, in: 0...23)
          }
        }
      }
      Stepper(
        "Höchstens \(state.config.securityMonitor.maximumAlertsPerDay) Hinweise pro Tag",
        value: $state.config.securityMonitor.maximumAlertsPerDay, in: 1...100)
      Stepper(
        "Befunde \(state.config.securityMonitor.retentionDays) Tage lokal aufbewahren",
        value: $state.config.securityMonitor.retentionDays, in: 1...365)
      Text(
        "Gleiche Befunde werden höchstens einmal innerhalb von 24 Stunden gemeldet. Details und Logauszüge werden nicht vorgelesen und verlassen den Mac nicht."
      )
      .font(.caption).foregroundStyle(.secondary)
    }
  }

  private var localIntelligenceCard: some View {
    SettingsCard(
      title: "Lokale Einordnung",
      subtitle: "Optionale verständliche Erklärung zusätzlich zur deterministischen Regelprüfung",
      symbol: "brain.head.profile"
    ) {
      Toggle(
        "Befunde mit der lokalen KI erklären",
        isOn: $state.config.securityMonitor.localAIEnabled)
      Label(localIntelligenceDescription, systemImage: localIntelligenceSymbol)
        .font(.caption).foregroundStyle(localIntelligenceColor)
      Text(
        "Die KI entscheidet nicht über die Kritikalität. Sie erklärt nur bereits erkannte Befunde, behandelt Logtexte als nicht vertrauenswürdige Daten und darf keine darin enthaltenen Anweisungen ausführen. Es gibt keinen Fallback zu OpenAI, OpenRouter oder OpenWebUI."
      )
      .font(.caption).foregroundStyle(.secondary)
      Button("Lokale Intelligenz konfigurieren") {
        state.showSetupWindow(initialPane: .intelligence)
      }
    }
  }

  private var testsCard: some View {
    SettingsCard(
      title: "Sicher testen",
      subtitle: "Simulationen ändern keine Systemeinstellung und erzeugen keinen echten Angriff",
      symbol: "testtube.2"
    ) {
      HStack {
        Button("Hinweis simulieren") { monitor.simulate(.info) }
        Button("Warnung simulieren") { monitor.simulate(.warning) }
        Button("Kritisch simulieren") { monitor.simulate(.critical) }
      }
      HStack {
        Button("Benachrichtigung testen") { monitor.testNotification() }
        Button("Sprachausgabe testen") { monitor.testVoice() }
        Spacer()
      }
    }
  }

  private var findingsCard: some View {
    SettingsCard(
      title: "Lokale Befunde",
      subtitle: monitor.historyStatus,
      symbol: "list.bullet.clipboard"
    ) {
      if !monitor.latestLocalSummary.isEmpty {
        Text(monitor.latestLocalSummary).font(.callout)
          .padding(12)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 11))
      }
      if monitor.findings.isEmpty {
        ContentUnavailableView(
          "Keine gespeicherten Befunde", systemImage: "checkmark.shield",
          description: Text("Nach bestätigter Baseline erscheinen Abweichungen hier.")
        )
        .frame(minHeight: 120)
      } else {
        Picker("Ansicht", selection: $findingFilter) {
          Text("Offen").tag("active")
          Text("Behoben").tag("resolved")
          Text("Alle").tag("all")
        }
        .pickerStyle(.segmented)
        ForEach(visibleFindings.prefix(50)) { finding in
          findingRow(finding)
          if finding.id != visibleFindings.prefix(50).last?.id { Divider() }
        }
        HStack {
          Button("Lokalen Bericht exportieren") { monitor.exportLocalReport() }
          Spacer()
          Button("Befundhistorie löschen", role: .destructive) {
            confirmsHistoryDeletion = true
          }
        }
      }
    }
  }

  private var limitsCard: some View {
    SettingsCard(
      title: "Schutzumfang und Grenzen",
      subtitle: "Transparenz statt falscher Sicherheitsversprechen",
      symbol: "info.circle"
    ) {
      Text(
        "MiddleAI überwacht Konfigurationsprofile einschließlich sicherheitsrelevanter Payloads, verwaltete Einstellungen, MDM-Zustand, zentrale macOS-Schutzfunktionen, Benutzer und Administratoren, einzelne Zertifikate und Vertrauensstellungen, DNS und Proxy, Systemerweiterungen, Anmeldeobjekte, Crontab, SSH-Schlüssel, Shell-Startdateien, persistente Autostarteinträge, MiddleAI selbst, Microsoft Defender sowie ausgewählte lokale Sicherheits- und Intune-Fehler."
      )
      Text(
        "Ohne Apple Developer Account verwendet MiddleAI keine Endpoint-Security-Systemerweiterung. Es sieht daher nicht jeden Prozess- oder Dateizugriff in Echtzeit und ersetzt weder Microsoft Defender noch ein professionelles EDR/SOC. Eine Meldung ist ein Prüfhinweis, kein Beweis für einen Angriff."
      )
      .foregroundStyle(.secondary)
      Text(
        "Baseline und Verlauf werden mit einem nur auf diesem Mac nutzbaren Schlüssel aus dem macOS-Schlüsselbund authentifiziert. Das erkennt nachträgliche Dateiänderungen deutlich zuverlässiger. Ein Angreifer mit vollständiger Kontrolle über den laufenden Benutzer, dessen Schlüsselbund und MiddleAI selbst bleibt dennoch außerhalb des belastbaren Schutzmodells."
      )
      .font(.caption).foregroundStyle(.secondary)
    }
  }

  @ViewBuilder private var severityOptions: some View {
    Text("Hinweis").tag("info")
    Text("Warnung").tag("warning")
    Text("Kritisch").tag("critical")
  }

  private func findingRow(_ finding: IntegrityFinding) -> some View {
    HStack(alignment: .top, spacing: 11) {
      Image(systemName: severitySymbol(finding.severity))
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(severityColor(finding.severity))
        .frame(width: 24)
      VStack(alignment: .leading, spacing: 5) {
        HStack {
          Text(finding.title).font(.callout.weight(.semibold))
          Text(finding.lifecycleState.title).font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(lifecycleColor(finding.lifecycleState).opacity(0.12), in: Capsule())
            .foregroundStyle(lifecycleColor(finding.lifecycleState))
          if finding.simulated {
            Text("Simulation").font(.caption2.weight(.medium))
              .padding(.horizontal, 6).padding(.vertical, 2)
              .background(Color.blue.opacity(0.10), in: Capsule())
          }
          Spacer()
          Text(
            (finding.resolvedAt ?? finding.detectedAt).formatted(
              date: .abbreviated, time: .shortened)
          )
          .font(.caption2).foregroundStyle(.secondary)
        }
        Text(finding.category.title).font(.caption).foregroundStyle(.secondary)
        Text(finding.detail).font(.caption)
        if !finding.evidence.isEmpty {
          Text(finding.evidence).font(.caption2).foregroundStyle(.secondary)
        }
        if finding.occurrenceCount > 1 {
          Text("\(finding.occurrenceCount) Mal erkannt")
            .font(.caption2).foregroundStyle(.secondary)
        }
        if let resolved = finding.resolvedAt {
          Text("Behoben: \(resolved.formatted(date: .abbreviated, time: .shortened))")
            .font(.caption2).foregroundStyle(.green)
        }
        HStack(spacing: 10) {
          if let source = finding.source {
            Button("Quelle öffnen") { monitor.openSource(for: finding) }
              .buttonStyle(.link)
            Text(source.title).font(.caption2).foregroundStyle(.secondary)
          }
          if finding.isActive, finding.lifecycleState != .acknowledged, !finding.simulated {
            Button("Als geprüft markieren") { monitor.acknowledge(finding) }
              .buttonStyle(.link)
          }
        }
      }
    }
    .contentShape(Rectangle())
    .onTapGesture {
      if finding.source != nil { monitor.openSource(for: finding) }
    }
  }

  private var visibleFindings: [IntegrityFinding] {
    switch findingFilter {
    case "active": return monitor.findings.filter(\.isActive)
    case "resolved": return monitor.findings.filter { !$0.isActive }
    default: return monitor.findings
    }
  }

  @ViewBuilder private func coverageView(_ report: IntegrityCoverageReport) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text("Quellenstatus: \(report.checkedCount) von \(report.expectedCount) geprüft")
        .font(.caption.weight(.semibold))
      ForEach(report.gaps) { gap in
        Label(
          "\(gap.title) nicht verfügbar\(gap.critical ? " · für Baseline erforderlich" : "")",
          systemImage: gap.critical ? "xmark.octagon.fill" : "exclamationmark.triangle.fill"
        )
        .font(.caption2).foregroundStyle(gap.critical ? .red : .orange)
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
  }

  private func lifecycleColor(_ state: IntegrityFindingState) -> Color {
    switch state {
    case .new: return .blue
    case .ongoing: return .orange
    case .escalated: return .red
    case .acknowledged: return .green
    case .resolved: return .secondary
    }
  }

  private func updateCategory(_ category: IntegrityCategory, enabled: Bool) {
    var categories = Set(state.config.securityMonitor.categories)
    if enabled {
      categories.insert(category.rawValue)
    } else if categories.count > 1 {
      categories.remove(category.rawValue)
    }
    state.config.securityMonitor.categories = IntegrityCategory.allCases.compactMap {
      categories.contains($0.rawValue) ? $0.rawValue : nil
    }
  }

  private var localIntelligenceDescription: String {
    guard state.config.securityMonitor.localAIEnabled else {
      return "Deaktiviert: Befunde werden ausschließlich regelbasiert dargestellt."
    }
    guard state.config.localLLM.enabled else {
      return "Noch kein lokaler KI-Anbieter aktiviert. Die Regelprüfung funktioniert trotzdem."
    }
    switch state.config.localLLM.provider {
    case "apple": return "Apple Intelligence wird ausschließlich auf diesem Mac verwendet."
    case "ollama":
      return "Ollama · \(state.config.localLLM.model) · \(state.config.localLLM.url)"
    default:
      return "llama.cpp · \(state.config.localLLM.model) · \(state.config.localLLM.url)"
    }
  }

  private var localIntelligenceSymbol: String {
    state.config.localLLM.enabled ? "checkmark.circle.fill" : "exclamationmark.circle"
  }

  private var localIntelligenceColor: Color {
    state.config.localLLM.enabled ? .green : .orange
  }

  private var statusSymbol: String {
    if monitor.scanRunning { return "arrow.triangle.2.circlepath" }
    if !state.config.securityMonitor.enabled { return "pause.circle" }
    return monitor.baselineAvailable ? "checkmark.shield.fill" : "exclamationmark.shield"
  }

  private var statusColor: Color {
    if !state.config.securityMonitor.enabled { return .secondary }
    return monitor.baselineAvailable ? .green : .orange
  }

  private func severitySymbol(_ severity: IntegritySeverity) -> String {
    switch severity {
    case .info: return "info.circle.fill"
    case .warning: return "exclamationmark.triangle.fill"
    case .critical: return "exclamationmark.octagon.fill"
    }
  }

  private func severityColor(_ severity: IntegritySeverity) -> Color {
    switch severity {
    case .info: return .blue
    case .warning: return .orange
    case .critical: return .red
    }
  }
}
