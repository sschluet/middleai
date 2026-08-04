import Darwin
import MiddleAICore
import SwiftUI

struct DiagnosticsPane: View {
  @ObservedObject var state: AppState

  var body: some View {
    VStack(spacing: 16) {
      SettingsCard(
        title: "Offline-Bereitschaft",
        subtitle: "Was ohne Internet sofort nutzbar ist und was noch vorbereitet werden muss",
        symbol: "wifi.slash"
      ) {
        ForEach(Array(state.offlineReadinessItems.enumerated()), id: \.offset) { index, item in
          HStack(alignment: .top, spacing: 12) {
            Image(systemName: readinessSymbol(item.state))
              .foregroundStyle(readinessColor(item.state))
              .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
              Text(item.title).font(.callout.weight(.medium))
              Text(readinessTitle(item.state))
                .font(.caption.weight(.semibold))
                .foregroundStyle(readinessColor(item.state))
              Text(item.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
          }
          if index < state.offlineReadinessItems.count - 1 { Divider() }
        }
      }

      SettingsCard(
        title: "Systemdiagnose",
        subtitle:
          "Prüft Konfiguration, lokale Dienste und den Antwortanbieter ohne Sprachinhalte zu protokollieren",
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
        Button("Datenschutzsicheren Supportbericht exportieren") { state.exportDiagnostics() }
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
        Label("Keine Diktate, Prompts oder Anbieter-Antworten", systemImage: "text.badge.xmark")
        Label(
          "Keine Serveradressen, Dateipfade, Modell-IDs oder Benutzernamen",
          systemImage: "network.slash")
        Label(
          "Fehlerdetails werden vollständig ausgelassen; nur freigegebene erfolgreiche Statuswerte erscheinen.",
          systemImage: "checklist.unchecked")
      }
    }
    .task {
      if state.diagnosticChecks.isEmpty { state.runDiagnostics() }
    }
  }

  private func readinessTitle(_ state: OfflineReadinessState) -> String {
    switch state {
    case .ready: return "Bereit"
    case .needsDownload: return "Download oder Vorbereitung nötig"
    case .needsService: return "Lokaler Dienst nötig"
    case .requiresNetwork: return "Netzwerk erforderlich"
    }
  }

  private func readinessSymbol(_ state: OfflineReadinessState) -> String {
    switch state {
    case .ready: return "checkmark.circle.fill"
    case .needsDownload: return "arrow.down.circle.fill"
    case .needsService: return "server.rack"
    case .requiresNetwork: return "network"
    }
  }

  private func readinessColor(_ state: OfflineReadinessState) -> Color {
    switch state {
    case .ready: return .green
    case .needsDownload, .needsService: return .orange
    case .requiresNetwork: return .secondary
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
