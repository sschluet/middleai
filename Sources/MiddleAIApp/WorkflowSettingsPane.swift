import MiddleAICore
import SwiftUI

struct WorkflowSettingsPane: View {
  @ObservedObject var state: AppState
  @ObservedObject var meeting: MeetingRecordingController
  @State private var meetingTitle = ""

  var body: some View {
    VStack(spacing: 16) {
      SettingsCard(
        title: "Assistent für markierten Text",
        subtitle: "Lokale Vorschau mit bewusster Freigabe vor dem Ersetzen",
        symbol: "selection.pin.in.out"
      ) {
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 150, maximum: 230), spacing: 9)], spacing: 9
        ) {
          SelectionCapabilityLabel("Korrigieren", symbol: "text.badge.checkmark")
          SelectionCapabilityLabel("Formulierung glätten", symbol: "wand.and.stars")
          SelectionCapabilityLabel(
            "Kürzen oder erweitern", symbol: "arrow.up.left.and.arrow.down.right")
          SelectionCapabilityLabel("In Stichpunkte", symbol: "list.bullet")
          SelectionCapabilityLabel("Deutsch oder Englisch", symbol: "character.bubble")
          SelectionCapabilityLabel("Antwortentwurf", symbol: "arrowshape.turn.up.left")
        }
        Text(state.selectionAssistantStatus).font(.caption).foregroundStyle(.secondary)
        Text(
          "Markiere Text in einer anderen Anwendung und wähle im Kontextmenü „Dienste > Mit MiddleAI bearbeiten…“. Alternativ bleibt „Markierten Text lokal bearbeiten“ im MiddleAI-Menü verfügbar. Nur diese Auswahl wird an den lokalen Ollama- oder llama.cpp-Server übergeben. In editierbaren Feldern kann MiddleAI den bestätigten Vorschlag einsetzen; bei Nur-Lesen-Inhalten aus Safari oder Edge wird er kopiert."
        )
        .font(.caption2).foregroundStyle(.secondary)
      }

      SettingsCard(
        title: "Lokales Besprechungsprotokoll",
        subtitle: "Nur nach bewusstem Start · Transkript, Zusammenfassung und Export bleiben lokal",
        symbol: "person.3.sequence.fill"
      ) {
        SettingsField(
          title: "Titel", prompt: "Optionaler Name der Besprechung", text: $meetingTitle
        )
        .disabled(meeting.isRecording || meeting.isProcessing)
        HStack(spacing: 10) {
          if meeting.isRecording {
            Button {
              state.stopMeeting()
            } label: {
              Label("Aufnahme beenden", systemImage: "stop.fill")
            }
            .buttonStyle(.borderedProminent)
            Button("Verwerfen", role: .destructive) { state.cancelMeeting() }
          } else {
            Button {
              state.startMeeting(title: meetingTitle)
            } label: {
              Label("Aufnahme starten", systemImage: "record.circle")
            }
            .buttonStyle(.borderedProminent)
            .disabled(meeting.isProcessing)
          }
          if meeting.isProcessing { ProgressView().controlSize(.small) }
          Spacer()
          if meeting.isRecording {
            LevelMeter(level: Double(meeting.level)).frame(width: 110)
          }
        }
        Label(
          meeting.status,
          systemImage: meeting.isRecording
            ? "waveform.circle.fill" : (meeting.isProcessing ? "gearshape.2" : "checkmark.circle")
        )
        .font(.caption).foregroundStyle(meeting.isRecording ? .red : .secondary)
        Text(
          "MiddleAI verwendet das unter Geräte gewählte Mikrofon. Es gibt keine Hintergrundaufnahme und keine automatische Aktivierung. Der aktuelle Modus erzeugt nach dem Stoppen ein lokales Transkript mit Zeitmarke sowie eine deterministische Zusammenfassung mit Entscheidungen und Aufgaben."
        )
        .font(.caption2).foregroundStyle(.secondary)
        if let session = meeting.lastSession {
          Divider()
          VStack(alignment: .leading, spacing: 6) {
            Text(session.title).font(.callout.weight(.semibold))
            if !session.summary.overview.isEmpty {
              Text(session.summary.overview).font(.caption).foregroundStyle(.secondary)
                .lineLimit(5)
            }
            HStack {
              Label("\(session.summary.decisions.count) Entscheidungen", systemImage: "checklist")
              Label(
                "\(session.summary.actionItems.count) Aufgaben", systemImage: "checkmark.square")
              Spacer()
              Button("Export im Finder zeigen") { meeting.revealLastExport() }
            }
            .font(.caption)
          }
        }
      }

      SettingsCard(
        title: "Sichere lokale Aktionen",
        subtitle: "Strukturierte Befehle statt beliebiger Automatisierung",
        symbol: "checkmark.shield"
      ) {
        Label("Neue Unterhaltung und Profilwechsel", systemImage: "bubble.left.and.bubble.right")
        Label(
          "Letzte Antwort kopieren und markierten Text bearbeiten",
          systemImage: "selection.pin.in.out")
        Label("Erinnerungen nur nach sichtbarer Bestätigung", systemImage: "bell.badge")
        Text(
          "Aktionsdaten werden gegen eine feste Allowlist und ein strenges Schema geprüft. MiddleAI führt darüber keine Shell-Befehle, unbekannten URLs oder frei vom Modell erzeugten Aktionen aus."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
    }
  }
}

private struct SelectionCapabilityLabel: View {
  let title: String
  let symbol: String

  init(_ title: String, symbol: String) {
    self.title = title
    self.symbol = symbol
  }

  var body: some View {
    Label(title, systemImage: symbol)
      .font(.callout)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 11).padding(.vertical, 9)
      .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
  }
}

private struct LevelMeter: View {
  let level: Double

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Capsule().fill(Color.primary.opacity(0.08))
        Capsule().fill(Color.accentColor).frame(
          width: geometry.size.width * min(1, max(0.02, level)))
      }
    }
    .frame(height: 7)
  }
}
