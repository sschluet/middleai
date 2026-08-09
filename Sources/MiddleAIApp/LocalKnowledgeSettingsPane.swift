import AppKit
import MiddleAICore
import SwiftUI

struct LocalKnowledgeSettingsPane: View {
  @ObservedObject var state: AppState
  @State private var memoryKey = ""
  @State private var memoryValue = ""
  @State private var memoryExpires = false
  @State private var memoryExpiry = Calendar.current.date(byAdding: .month, value: 3, to: Date())!

  var body: some View {
    VStack(spacing: 16) {
      SettingsCard(
        title: "Freigegebene Wissensquellen",
        subtitle:
          "MiddleAI durchsucht ausschließlich Dateien und Unterordner, die du hier auswählst",
        symbol: "folder.badge.gearshape"
      ) {
        if state.knowledgeSources.isEmpty {
          ContentUnavailableView(
            "Noch keine Wissensquelle",
            systemImage: "folder.badge.plus",
            description: Text(
              "Füge eine konkrete Textdatei oder einen Projektordner hinzu. Versteckte und sensible Pfade werden abgelehnt."
            )
          )
          .frame(maxWidth: .infinity, minHeight: 150)
        } else {
          ForEach(state.knowledgeSources) { source in
            HStack(alignment: .top, spacing: 11) {
              Image(systemName: source.kind == .directory ? "folder.fill" : "doc.text.fill")
                .foregroundStyle(Color.accentColor).frame(width: 22)
              VStack(alignment: .leading, spacing: 3) {
                Text(source.displayName).font(.callout.weight(.semibold))
                Text(source.path).font(.caption2).foregroundStyle(.secondary)
                  .lineLimit(1).textSelection(.enabled)
                Text(
                  source.lastIndexedAt.map {
                    "Zuletzt indiziert: \($0.formatted(date: .abbreviated, time: .shortened))"
                  }
                    ?? "Noch nicht indiziert"
                )
                .font(.caption2).foregroundStyle(.secondary)
              }
              Spacer()
              Toggle(
                "Aktiv",
                isOn: Binding(
                  get: { source.enabled },
                  set: { state.setKnowledgeSource(source, enabled: $0) })
              )
              .labelsHidden()
              Menu {
                Button("Neu indizieren") { state.reindexKnowledgeSource(source) }
                Button("Im Finder zeigen") {
                  NSWorkspace.shared.activateFileViewerSelecting([
                    URL(fileURLWithPath: source.path)
                  ])
                }
                Divider()
                Button("Freigabe und Index entfernen", role: .destructive) {
                  state.removeKnowledgeSource(source)
                }
              } label: {
                Image(systemName: "ellipsis.circle")
              }
              .menuStyle(.borderlessButton)
            }
            if source.id != state.knowledgeSources.last?.id { Divider() }
          }
        }
        HStack {
          Button {
            chooseKnowledgeSource()
          } label: {
            Label("Datei oder Ordner freigeben", systemImage: "plus")
          }
          .buttonStyle(.borderedProminent)
          .disabled(state.knowledgeIndexing)
          if state.knowledgeIndexing { ProgressView().controlSize(.small) }
          Spacer()
          Text(state.knowledgeStatus).font(.caption).foregroundStyle(.secondary)
        }
        Label(
          "Unterstützt werden lokale Text-, Markdown-, CSV-, JSON-, YAML- und HTML-Dateien. MiddleAI überspringt versteckte Dateien, Symlinks, Schlüssel, Maildatenbanken und Dateien über 8 MB.",
          systemImage: "checkmark.shield"
        )
        .font(.caption2).foregroundStyle(.secondary)
        Label(
          "Wissensabschnitte werden nur einem lokalen Antwortanbieter oder einem OpenWebUI-Server auf diesem Mac bereitgestellt. Entfernte Anbieter erhalten diesen Kontext nicht.",
          systemImage: "network.slash"
        )
        .font(.caption2).foregroundStyle(.secondary)
      }

      SettingsCard(
        title: "Persönliche Hinweise",
        subtitle: "Explizites, profilbezogenes Gedächtnis ohne automatisches Lernen",
        symbol: "brain.head.profile.fill"
      ) {
        SettingsField(title: "Titel", prompt: "z. B. Schreibstil", text: $memoryKey)
        VStack(alignment: .leading, spacing: 6) {
          Text("Inhalt").foregroundStyle(.secondary)
          TextEditor(text: $memoryValue)
            .frame(minHeight: 82)
            .padding(8)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
            .overlay {
              RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.08))
            }
        }
        Toggle("Hinweis automatisch ablaufen lassen", isOn: $memoryExpires)
        if memoryExpires {
          DatePicker("Ablaufdatum", selection: $memoryExpiry, in: Date()...)
            .datePickerStyle(.compact)
        }
        HStack {
          Button("Hinweis für aktives Profil speichern") {
            state.addProfileMemory(
              key: memoryKey, value: memoryValue,
              expiresAt: memoryExpires ? memoryExpiry : nil)
            memoryKey = ""
            memoryValue = ""
          }
          .buttonStyle(.borderedProminent)
          .disabled(
            memoryKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              || memoryValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          Spacer()
          Text(state.profileMemoryStatus).font(.caption).foregroundStyle(.secondary)
        }
        if !state.profileMemories.isEmpty {
          Divider()
          ForEach(state.profileMemories) { memory in
            HStack(alignment: .top, spacing: 10) {
              VStack(alignment: .leading, spacing: 3) {
                Text(memory.key).font(.callout.weight(.semibold))
                Text(memory.value).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                if let expiresAt = memory.expiresAt {
                  Text("Läuft ab: \(expiresAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption2).foregroundStyle(.orange)
                }
              }
              Spacer()
              Button(role: .destructive) {
                state.removeProfileMemory(memory)
              } label: {
                Image(systemName: "trash")
              }
              .buttonStyle(.borderless)
            }
          }
        }
        Text(
          "MiddleAI liest keine Unterhaltungen aus, um selbstständig Erinnerungen anzulegen. Nur diese sichtbaren Einträge werden bei passenden lokalen Anfragen verwendet und können jederzeit einzeln gelöscht werden."
        )
        .font(.caption2).foregroundStyle(.secondary)
      }
    }
    .onAppear { state.refreshLocalContext() }
  }

  private func chooseKnowledgeSource() {
    let panel = NSOpenPanel()
    panel.title = "Lokale Wissensquelle freigeben"
    panel.message =
      "MiddleAI indiziert ausschließlich die ausgewählte Datei oder den ausgewählten Ordner."
    panel.prompt = "Freigeben und indizieren"
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.resolvesAliases = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    state.addKnowledgeSource(url)
  }
}
