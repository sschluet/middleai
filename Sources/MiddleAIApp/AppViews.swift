import AppKit
import MiddleAICore
import SwiftUI

struct MenuContent: View {
  @ObservedObject var state: AppState
  var body: some View {
    Text("Status: \(state.status)")
    Text(state.voiceStatus).font(.caption)
    Text(state.ttsStatus).font(.caption)
    Text("Current Conversation:")
    Text(state.currentTitle).font(.caption)
    Divider()
    Menu(
      "Profile: \(state.engine?.activeProfile.capitalized ?? state.config.activeProfile.capitalized)"
    ) {
      ForEach(["default", "management", "architecture", "coding", "research"], id: \.self) {
        profile in
        Button(profile.capitalized) {
          state.submit(
            profile == "architecture"
              ? "Architekturmodus"
              : profile == "coding"
                ? "Codingmodus"
                : profile == "management"
                  ? "Managementmodus" : profile == "research" ? "Recherchemodus" : "Standardmodus")
        }
      }
    }
    Divider()
    Button("Quick Input…") { state.showQuickInput() }
    Button("Setup / Settings…") { state.showSetupWindow() }
    Button("Hilfe & Systemanforderungen…") { state.showHelpWindow() }
    Button("New Conversation") { state.newConversation() }
    Button("Stop Speaking") { state.stopSpeaking() }
    Button("Open Current Chat in Open WebUI") { state.openCurrentChat() }.disabled(
      state.engine?.manager.currentConversation?.openWebUIChatID == nil)
    Divider()
    SettingsLink { Text("Settings") }
    Button("Diagnostics") { state.submit("Welcher Chat ist gerade aktiv?") }
    if !state.lastError.isEmpty { Text(state.lastError).font(.caption).foregroundStyle(.red) }
    Divider()
    Button("Quit MiddleAI") { NSApplication.shared.terminate(nil) }
  }
}

struct QuickInputView: View {
  @ObservedObject var state: AppState
  @FocusState private var focused: Bool
  @State private var searchText = ""

  private var filteredConversations: [Conversation] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return state.conversations }
    return state.conversations.filter {
      ($0.title + " " + $0.summary).localizedCaseInsensitiveContains(query)
    }
  }

  var body: some View {
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 14) {
        HStack(spacing: 10) {
          MiddleAIIconView(cornerRadius: 9).frame(width: 36, height: 36)
          VStack(alignment: .leading, spacing: 1) {
            Text("MiddleAI").font(.headline)
            Text("Lokaler Sprachassistent").font(.caption).foregroundStyle(.secondary)
          }
        }
        .padding(.horizontal, 14)

        Button {
          state.newConversation()
          focused = true
        } label: {
          Label("Neue Unterhaltung", systemImage: "square.and.pencil")
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .padding(.horizontal, 12)

        HStack(spacing: 8) {
          Image(systemName: "magnifyingglass")
            .foregroundStyle(.secondary)
          TextField("Unterhaltungen suchen", text: $searchText)
            .textFieldStyle(.plain)
          if !searchText.isEmpty {
            Button {
              searchText = ""
            } label: {
              Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal, 11)
        .frame(height: 34)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
          RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.07))
        }
        .padding(.horizontal, 12)

        ScrollView {
          LazyVStack(spacing: 4) {
            ForEach(filteredConversations) { conversation in
              ConversationSidebarRow(
                conversation: conversation,
                selected: conversation.id == state.engine?.manager.currentConversation?.id
              ) {
                state.activateConversation(conversation)
              }
            }
          }
          .padding(.horizontal, 8)
        }
      }
      .padding(.vertical, 16)
      .frame(width: 252)
      .background(.ultraThinMaterial)

      Divider()

      VStack(spacing: 0) {
        HStack(spacing: 12) {
          VStack(alignment: .leading, spacing: 3) {
            Text(state.currentTitle)
              .font(.title3.weight(.semibold))
              .lineLimit(1)
            Text(state.engine?.activeProfile.capitalized ?? "Default")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          HStack(spacing: 6) {
            Circle()
              .fill(state.status == "Connected" ? Color.green : Color.orange)
              .frame(width: 7, height: 7)
            Text(state.status == "Connected" ? "Verbunden" : "Offline")
              .font(.caption.weight(.medium))
              .foregroundStyle(.secondary)
          }
          .padding(.horizontal, 9).padding(.vertical, 5)
          .background(Color.primary.opacity(0.045), in: Capsule())
          if state.engine?.manager.currentConversation?.openWebUIChatID != nil {
            Button {
              state.openCurrentChat()
            } label: {
              Label("Open WebUI", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.bordered)
          }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 15)

        Divider()

        ZStack {
          ScrollView {
            if state.responseText.isEmpty && !state.isWorking {
              VStack(spacing: 14) {
                MiddleAIIconView(cornerRadius: 17)
                  .frame(width: 70, height: 70)
                Text("Womit kann ich helfen?")
                  .font(.title2.weight(.semibold))
                Text(
                  "Schreibe eine Nachricht oder nutze die rechte Optionstaste für eine Sprachanfrage."
                )
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 430)
              }
              .frame(maxWidth: .infinity, minHeight: 370)
            } else if !state.responseText.isEmpty {
              Text(state.responseText)
                .font(.body)
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(22)
                .background(
                  Color(nsColor: .controlBackgroundColor).opacity(0.76),
                  in: RoundedRectangle(cornerRadius: 19, style: .continuous)
                )
                .overlay {
                  RoundedRectangle(cornerRadius: 19, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07))
                }
                .shadow(color: .black.opacity(0.035), radius: 10, y: 4)
                .padding(24)
            }
          }

          if state.isWorking {
            VStack(spacing: 12) {
              ProgressView().controlSize(.small)
              Text("OpenWebUI erstellt die Antwort")
                .font(.callout.weight(.medium))
              Text("Ein Druck auf die rechte Optionstaste bricht ab.")
                .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        if !state.lastError.isEmpty {
          Label(state.lastError, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.red)
            .textSelection(.enabled)
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
        }

        HStack(alignment: .bottom, spacing: 12) {
          TextField("Nachricht an MiddleAI", text: $state.input, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...5)
            .focused($focused)
            .disabled(state.isWorking)
            .onSubmit { state.submit() }
          Button {
            state.submit()
          } label: {
            Image(systemName: "arrow.up")
              .font(.system(size: 13, weight: .bold))
              .frame(width: 26, height: 26)
          }
          .buttonStyle(.borderedProminent)
          .buttonBorderShape(.circle)
          .disabled(
            state.isWorking || state.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 17, style: .continuous)
            .strokeBorder(.quaternary, lineWidth: 0.8)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 18)
      }
      .background(
        LinearGradient(
          colors: [Color(nsColor: .windowBackgroundColor), Color.accentColor.opacity(0.025)],
          startPoint: .top, endPoint: .bottom))
    }
    .frame(minWidth: 820, minHeight: 560)
    .onAppear { focused = true }
    .onReceive(NotificationCenter.default.publisher(for: .middleAIQuickInputFocus)) { _ in
      focused = true
    }
  }
}

struct ConversationSidebarRow: View {
  let conversation: Conversation
  let selected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        Image(systemName: "bubble.left.and.text.bubble.right")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(selected ? Color.accentColor : .secondary)
          .frame(width: 18)
        VStack(alignment: .leading, spacing: 3) {
          Text(conversation.title)
            .font(.callout.weight(selected ? .semibold : .regular))
            .lineLimit(1)
          Text(conversation.lastUsedAt, style: .relative)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .contentShape(Rectangle())
      .background(
        selected ? Color.accentColor.opacity(0.12) : Color.clear,
        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
    .buttonStyle(.plain)
  }
}

struct LegacySettingsView: View {
  @ObservedObject var state: AppState
  @State private var password = ""
  @State private var message = ""
  var body: some View {
    TabView {
      Form {
        if state.needsSetup {
          Text("Welcome to MiddleAI").font(.title2)
          Text(
            "Enter your private Open WebUI connection. The password is stored only in macOS Keychain."
          )
        }
        TextField("Open WebUI URL", text: $state.config.openwebui.url)
        TextField("Username / email", text: $state.config.openwebui.username)
        SecureField("Password", text: $password)
        TextField("Model ID", text: $state.config.openwebui.model)
        Toggle("Verify TLS certificates", isOn: $state.config.openwebui.tlsVerify)
        TextField(
          "Custom CA file (optional)",
          text: Binding(
            get: { state.config.openwebui.caFile ?? "" },
            set: { state.config.openwebui.caFile = $0.isEmpty ? nil : $0 }))
        HStack {
          Button("Save & Test Connection") { save() }
          Text(message).foregroundStyle(message.hasPrefix("Saved") ? .green : .red)
        }
      }.padding().tabItem { Label("Connection", systemImage: "network") }
      Form {
        Picker("Routing strategy", selection: $state.config.routing.strategy) {
          Text("Hybrid").tag("hybrid")
          Text("Heuristic").tag("heuristic")
        }
        TextField(
          "Continuation timeout (seconds)", value: $state.config.routing.continuationTimeoutSeconds,
          format: .number)
        Toggle("Use local routing LLM", isOn: $state.config.localLLM.enabled)
        TextField("Local router URL", text: $state.config.localLLM.url)
        TextField("Local router model", text: $state.config.localLLM.model)
      }.padding().tabItem { Label("Routing", systemImage: "arrow.triangle.branch") }
      Form {
        Toggle(
          "Antworten vorlesen",
          isOn: Binding(
            get: { state.config.tts.enabled },
            set: {
              state.config.tts.enabled = $0
              state.applySpeechSettings()
            }))
        Picker(
          "Sprachmodell",
          selection: Binding(
            get: { state.config.tts.provider },
            set: { state.selectTTSProvider($0) })
        ) {
          Text("Qwen3-TTS · lokal · natürlichstes Deutsch").tag("qwen3_tts")
          Text("Mistral Voxtral · lokal · nicht-kommerziell").tag("voxtral_tts")
          Text("Supertonic 3 · lokal · beste Qualität").tag("supertonic3")
          Text("Apple-Systemstimmen · lokal").tag("macos")
          Text("PocketTTS · lokal · älteres Modell").tag("pockettts")
          Text("Eigenes lokales Programm").tag("local_model")
        }
        Text(providerDescription)
          .font(.callout)
          .foregroundStyle(.secondary)

        if !state.availableTTSVoices.isEmpty {
          Section("Verfügbare Stimmen") {
            ForEach(state.availableTTSVoices) { voice in
              Button {
                state.selectTTSVoice(voice.id)
              } label: {
                HStack(alignment: .top, spacing: 10) {
                  Image(systemName: voice.isFemale ? "person.wave.2" : "person.wave.2.fill")
                    .frame(width: 18)
                    .foregroundStyle(
                      state.config.tts.voice == voice.id ? Color.accentColor : .secondary)
                  VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                      Text(voice.name).font(.body.weight(.medium))
                      if voice.isRecommended {
                        Text("Empfohlen")
                          .font(.caption2.weight(.semibold))
                          .foregroundStyle(.secondary)
                      }
                    }
                    Text(voice.description)
                      .font(.caption)
                      .foregroundStyle(.secondary)
                      .fixedSize(horizontal: false, vertical: true)
                  }
                  Spacer(minLength: 8)
                  if state.config.tts.voice == voice.id {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                  }
                }
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
            }
          }
          Text("Beim Auswählen wird automatisch eine deutsche Hörprobe abgespielt.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if state.config.tts.provider == "supertonic3" || state.config.tts.provider == "pockettts" {
          Picker("Modellqualität", selection: $state.config.tts.quality) {
            Text("Hohe Qualität").tag("high")
            Text("Schneller").tag("fast")
          }
        }
        if state.config.tts.provider == "pockettts" {
          Slider(value: $state.config.tts.temperature, in: 0.35...0.9) {
            Text("Ausdruck")
          }
        }
        Slider(value: $state.config.tts.rate, in: 0.7...1.4) { Text("Sprechtempo") }
        if state.config.tts.provider == "local_model" {
          TextField("Lokales TTS-Programm", text: $state.config.tts.localCommand)
        }
        if state.config.tts.provider == "macos" {
          Button("Weitere Apple-Stimmen laden…") { openAppleVoiceSettings() }
        }
        Text(state.ttsStatus).font(.caption).foregroundStyle(.secondary)
        HStack {
          Button("Deutsche Hörprobe") { state.testTTS() }
          Button("Einstellungen anwenden") { state.applySpeechSettings() }
          Button("Lokales Modell vorbereiten") { state.prepareTTSModel() }
        }
        Text(
          "STT und TTS laufen vollständig lokal. Nach dem einmaligen Modelldownload werden keine Sprachdaten an einen Cloud-Dienst gesendet."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }.padding().tabItem { Label("Sprache", systemImage: "speaker.wave.2") }
      Form {
        Text("MiddleAI Voice").font(.headline)
        LabeledContent("Linke Optionstaste", value: "Diktat ins aktive Textfeld")
        LabeledContent("Rechte Optionstaste", value: "Anfrage an OpenWebUI")
        Text(
          "Kurz drücken startet oder beendet die Aufnahme. Gedrückthalten und Loslassen funktioniert ebenfalls."
        )
        .font(.caption)
        Section("Diktat-Nachbearbeitung") {
          Toggle(
            "Diktat vor dem Einfügen lokal glätten",
            isOn: Binding(
              get: { state.config.dictation.polishWithLocalAI },
              set: { state.setDictationPolishing($0) }))
          Text(
            "Entfernt Füllwörter und Wortwiederholungen und korrigiert Versprecher sowie Zeichensetzung behutsam. Inhalt, Namen, Zahlen, Fachbegriffe und Anrede sollen unverändert bleiben."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          Text(state.dictationPolishingStatus)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Text("Status: \(state.voiceStatus)").font(.caption)
        Text(
          "Die Erkennung läuft mit Parakeet TDT v3 lokal auf dem Mac. Beim ersten Start wird das Modell einmalig geladen."
        ).font(.caption)
        Text(
          "Für das Einfügen und die globalen Optionstasten benötigt MiddleAI Mikrofon, Bedienungshilfen und Eingabeüberwachung."
        ).font(.caption)
        Button("Datenschutz-Einstellungen öffnen") {
          if let url = URL(
            string:
              "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
          {
            NSWorkspace.shared.open(url)
          }
        }
        Text("Configuration: \(ConfigLoader.defaultURL.path)").font(.caption)
      }.padding().tabItem { Label("Voice", systemImage: "waveform.and.mic") }
    }
  }
  private func save() {
    do {
      try state.save(password: password)
      message = "Saved. Testing…"
      Task {
        await state.connectAndServe()
        message = state.status == "Connected" ? "Saved and connected" : "Saved; \(state.lastError)"
      }
    } catch { message = error.localizedDescription }
  }
  private var providerDescription: String {
    switch state.config.tts.provider {
    case "qwen3_tts":
      return
        "Qwen3-TTS VoiceDesign erzeugt eine frei gestaltete weibliche Stimme mit neutralem Standarddeutsch lokal über Apple MLX. Die 4-Bit-Version benötigt etwa 2,3 GB."
    case "voxtral_tts":
      return
        "Mistral Voxtral läuft lokal über MLX und bietet eine deutsche Frauenstimme. Die CC-BY-NC-4.0-Modelllizenz schließt kommerzielle Nutzung aus."
    case "supertonic3":
      return
        "Supertonic 3 erzeugt Deutsch mit einem mehrsprachigen Core-ML-Modell in 44,1 kHz. Der erste Download benötigt ungefähr 400 MB; danach läuft alles offline."
    case "macos":
      return
        "Verwendet die in macOS installierten deutschen Stimmen. Zusätzliche und höherwertige Apple-Stimmen lassen sich in den Systemeinstellungen laden."
    case "pockettts":
      return
        "PocketTTS bleibt aus Kompatibilitätsgründen verfügbar. Viele Stimmstile wurden nicht speziell für Deutsch aufgenommen und können deshalb einen Akzent haben."
    default:
      return
        "Startet ein selbst bereitgestelltes lokales TTS-Programm. MiddleAI übergibt ihm ausschließlich den zu sprechenden Text."
    }
  }
  private func openAppleVoiceSettings() {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent"
      )
    else { return }
    NSWorkspace.shared.open(url)
  }
}
