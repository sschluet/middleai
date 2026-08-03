import Darwin
import SwiftUI

struct DiagnosticsPane: View {
  @ObservedObject var state: AppState

  var body: some View {
    VStack(spacing: 16) {
      SettingsCard(
        title: "Systemdiagnose",
        subtitle:
          "Prüft Konfiguration, lokale Dienste und OpenWebUI ohne Sprachinhalte zu protokollieren",
        symbol: "stethoscope"
      ) {
        if state.diagnosticChecks.isEmpty {
          ContentUnavailableView(
            "Noch keine Diagnose",
            systemImage: "checkmark.shield",
            description: Text(
              "Starte die Prüfung, um Berechtigungen, Speicher, Modelle und Verbindung zu kontrollieren."
            )
          )
          .frame(maxWidth: .infinity, minHeight: 180)
        } else {
          ForEach(Array(state.diagnosticChecks.enumerated()), id: \.offset) { _, check in
            HStack(alignment: .top, spacing: 12) {
              Image(
                systemName: check.passed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
              )
              .foregroundStyle(check.passed ? Color.green : Color.orange)
              .frame(width: 22)
              VStack(alignment: .leading, spacing: 3) {
                Text(check.name).font(.callout.weight(.medium))
                if let detail = check.detail, !detail.isEmpty {
                  Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
              }
              Spacer()
            }
            if check.name != state.diagnosticChecks.last?.name { Divider() }
          }
        }
      }

      HStack {
        Button {
          state.runDiagnostics()
        } label: {
          if state.diagnosticsRunning {
            ProgressView().controlSize(.small)
          } else {
            Label("Diagnose starten", systemImage: "play.fill")
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(state.diagnosticsRunning)
        Button("Redigierten Bericht exportieren") { state.exportDiagnostics() }
          .buttonStyle(.bordered)
          .disabled(state.diagnosticChecks.isEmpty)
        Spacer()
      }

      SettingsCard(
        title: "Im Diagnosebericht nicht enthalten",
        subtitle: "Der Export ist für Supportanfragen gedacht",
        symbol: "hand.raised.fill"
      ) {
        Label("Keine Passwörter, Tokens oder Schlüsselbundinhalte", systemImage: "key.slash")
        Label("Keine Diktate, Prompts oder OpenWebUI-Antworten", systemImage: "text.badge.xmark")
        Label("Serveradressen werden im Export ausgeblendet", systemImage: "network.slash")
      }
    }
    .task {
      if state.diagnosticChecks.isEmpty { state.runDiagnostics() }
    }
  }
}

extension ProcessInfo {
  var machineHardwareName: String {
    var size = 0
    sysctlbyname("hw.machine", nil, &size, nil, 0)
    var value = [CChar](repeating: 0, count: max(size, 1))
    sysctlbyname("hw.machine", &value, &size, nil, 0)
    let bytes = value.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
  }
}
