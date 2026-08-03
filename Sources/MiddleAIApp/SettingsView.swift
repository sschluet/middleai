import AppKit
import MiddleAICore
import SwiftUI
import UniformTypeIdentifiers

enum MiddleAISettingsPane: String, CaseIterable, Identifiable {
  case connection
  case devices
  case speech
  case voice
  case intelligence
  case diagnostics
  case help

  var id: String { rawValue }
  var title: String {
    switch self {
    case .connection: return "Verbindung"
    case .devices: return "Geräte"
    case .speech: return "Sprachausgabe"
    case .voice: return "Spracheingabe"
    case .intelligence: return "Intelligenz"
    case .diagnostics: return "Diagnose"
    case .help: return "Hilfe"
    }
  }
  var subtitle: String {
    switch self {
    case .connection: return "KI-Anbieter und Modell"
    case .devices: return "Mikrofon und Lautsprecher"
    case .speech: return "Stimmen und Kurzfassungen"
    case .voice: return "Aktivierungstasten und Diktat"
    case .intelligence: return "Routing und lokale Modelle"
    case .diagnostics: return "Berechtigungen und Systemstatus"
    case .help: return "Installation und Anforderungen"
    }
  }
  var symbol: String {
    switch self {
    case .connection: return "network"
    case .devices: return "hifispeaker.2"
    case .speech: return "speaker.wave.3"
    case .voice: return "waveform.and.mic"
    case .intelligence: return "brain.head.profile"
    case .diagnostics: return "stethoscope"
    case .help: return "questionmark.circle"
    }
  }
}

struct SettingsView: View {
  @ObservedObject var state: AppState
  @State private var selected: MiddleAISettingsPane?
  @State private var password = ""
  @State private var saveMessage = ""
  @State private var ttsModelToDelete: TTSModelDownloadStatus?
  @State private var showsVoxtralLicenseConfirmation = false
  @State private var confirmsCacheDeletion = false
  @State private var audioInputDevices = AudioInputDeviceCatalog.availableDevices()
  @State private var audioOutputDevices = AudioOutputDeviceCatalog.availableDevices()

  init(state: AppState, initialPane: MiddleAISettingsPane = .connection) {
    self.state = state
    _selected = State(initialValue: initialPane)
  }

  var body: some View {
    NavigationSplitView {
      VStack(spacing: 0) {
        HStack(spacing: 11) {
          MiddleAIIconView(cornerRadius: 10).frame(width: 40, height: 40)
          VStack(alignment: .leading, spacing: 2) {
            Text("MiddleAI").font(.headline)
            Text("Einstellungen").font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
        }
        .padding(16)

        List(MiddleAISettingsPane.allCases, selection: $selected) { pane in
          Label {
            VStack(alignment: .leading, spacing: 2) {
              Text(pane.title).font(.callout.weight(.medium))
              Text(pane.subtitle).font(.caption2).foregroundStyle(.secondary)
            }
          } icon: {
            Image(systemName: pane.symbol)
              .foregroundStyle(selected == pane ? Color.accentColor : .secondary)
              .frame(width: 21)
          }
          .tag(pane)
          .padding(.vertical, 4)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)

        VStack(alignment: .leading, spacing: 5) {
          Label(
            state.status,
            systemImage: state.status == "Connected" ? "checkmark.circle.fill" : "circle.dotted"
          )
          .font(.caption.weight(.medium))
          .foregroundStyle(state.status == "Connected" ? .green : .secondary)
          Text(state.voiceStatus).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .background(.ultraThinMaterial)
      .navigationSplitViewColumnWidth(min: 220, ideal: 235, max: 260)
    } detail: {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          paneHeader
          switch selected ?? .connection {
          case .connection: connectionPane
          case .devices: devicesPane
          case .speech: speechPane
          case .voice: voicePane
          case .intelligence: intelligencePane
          case .diagnostics: DiagnosticsPane(state: state)
          case .help: helpPane
          }
        }
        .padding(28)
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .top)
      }
      .background(
        LinearGradient(
          colors: [
            Color(nsColor: .windowBackgroundColor),
            Color.accentColor.opacity(0.035),
          ], startPoint: .top, endPoint: .bottom))
    }
    .navigationSplitViewStyle(.balanced)
  }

  private var paneHeader: some View {
    let pane = selected ?? .connection
    return HStack(spacing: 15) {
      ZStack {
        RoundedRectangle(cornerRadius: 15, style: .continuous)
          .fill(
            LinearGradient(
              colors: [Color.accentColor.opacity(0.18), Color.purple.opacity(0.10)],
              startPoint: .topLeading, endPoint: .bottomTrailing))
        Image(systemName: pane.symbol)
          .font(.system(size: 21, weight: .semibold))
          .foregroundStyle(Color.accentColor)
      }
      .frame(width: 50, height: 50)
      VStack(alignment: .leading, spacing: 3) {
        Text(pane.title).font(.title2.weight(.semibold))
        Text(pane.subtitle).font(.callout).foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Spacer(minLength: 12)
      Text(
        state.status == "Connected"
          ? "\(state.config.assistantProviderTitle) verbunden" : "Lokal konfiguriert"
      )
      .font(.caption.weight(.medium))
      .lineLimit(1)
      .fixedSize(horizontal: true, vertical: false)
      .foregroundStyle(state.status == "Connected" ? Color.green : .secondary)
      .padding(.horizontal, 10).padding(.vertical, 6)
      .background(Color.primary.opacity(0.045), in: Capsule())
    }
  }

  private var connectionPane: some View {
    VStack(spacing: 16) {
      SettingsCard(
        title: "Antwortanbieter", subtitle: "Wohin MiddleAI deine gesprochenen Anfragen sendet",
        symbol: "point.3.connected.trianglepath.dotted"
      ) {
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 155, maximum: 240), spacing: 10)],
          alignment: .leading, spacing: 10
        ) {
          ProviderSelectionCard(
            title: "OpenWebUI", subtitle: "Eigener Server", symbol: "server.rack",
            selected: state.config.assistant.provider == "openwebui"
          ) { selectAssistantProvider("openwebui") }
          ProviderSelectionCard(
            title: "OpenAI", subtitle: "Platform API", symbol: "sparkles",
            selected: state.config.assistant.provider == "openai"
          ) { selectAssistantProvider("openai") }
          ProviderSelectionCard(
            title: "OpenRouter", subtitle: "Modell-Router", symbol: "arrow.triangle.branch",
            selected: state.config.assistant.provider == "openrouter"
          ) { selectAssistantProvider("openrouter") }
        }
        Text(answerProviderDescription).font(.caption).foregroundStyle(.secondary)
        Label(
          "Beim Anbieterwechsel startet MiddleAI eine neue Unterhaltung, damit alter Gesprächskontext nicht unbeabsichtigt an einen anderen Dienst übertragen wird.",
          systemImage: "lock.shield"
        )
        .font(.caption2).foregroundStyle(.secondary)
      }

      SettingsCard(
        title: state.config.assistantProviderTitle,
        subtitle: state.config.assistant.provider == "openwebui"
          ? "Server und Anmeldung" : "API-Zugriff und Modell",
        symbol: state.config.assistant.provider == "openwebui" ? "server.rack" : "key"
      ) {
        if state.config.assistant.provider == "openwebui" {
          SettingsField(
            title: "Server", prompt: "https://chat.example.com", text: $state.config.openwebui.url)
          SettingsField(
            title: "Benutzer", prompt: "name@firma.de", text: $state.config.openwebui.username)
        }
        HStack(alignment: .firstTextBaseline, spacing: 18) {
          Text(state.config.assistant.provider == "openwebui" ? "Passwort" : "API-Schlüssel")
            .frame(width: 112, alignment: .leading).foregroundStyle(.secondary)
          SecureField("Unverändert lassen oder neu eingeben", text: $password)
            .textFieldStyle(.roundedBorder)
        }
        Text(
          "Das Geheimnis wird ausschließlich im macOS-Schlüsselbund gespeichert und nie in die Konfigurationsdatei geschrieben."
        )
        .font(.caption2).foregroundStyle(.secondary)
        HStack {
          Button {
            Task { await state.loadProviderModels(secret: password) }
          } label: {
            Label("Authentifizieren und Modelle laden", systemImage: "arrow.down.circle")
          }
          .buttonStyle(.bordered)
          Text(state.providerModelStatus).font(.caption).foregroundStyle(.secondary)
        }
        if !state.providerModels.isEmpty {
          Picker("Verfügbares Modell", selection: assistantModelBinding) {
            ForEach(state.providerModels, id: \.self) { Text($0).tag($0) }
          }
          .pickerStyle(.menu)
        }
        SettingsField(
          title: "Modell-ID", prompt: "Modell auswählen oder ID eintragen",
          text: assistantModelBinding)
        if state.config.assistant.provider == "openwebui" {
          Divider()
          Toggle("TLS-Zertifikate überprüfen", isOn: $state.config.openwebui.tlsVerify)
          SettingsField(
            title: "Eigene CA", prompt: "Optionaler Dateipfad",
            text: Binding(
              get: { state.config.openwebui.caFile ?? "" },
              set: { state.config.openwebui.caFile = $0.isEmpty ? nil : $0 }))
        } else {
          Label(
            "Anfragen und Gesprächskontext werden an \(state.config.assistantProviderTitle) übertragen. STT, Diktat und TTS bleiben lokal.",
            systemImage: "info.circle"
          )
          .font(.caption).foregroundStyle(.secondary)
        }
      }

      HStack(spacing: 12) {
        Button {
          saveConnection()
        } label: {
          Label("Speichern und verbinden", systemImage: "bolt.horizontal.circle")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        if !saveMessage.isEmpty {
          Text(saveMessage)
            .font(.callout)
            .foregroundStyle(saveMessage.contains("verbunden") ? .green : .red)
        }
        Spacer()
      }
    }
  }

  private var devicesPane: some View {
    VStack(spacing: 16) {
      SettingsCard(
        title: "Audioeingang", subtitle: "Mikrofon für Diktat und MiddleAI-Anfragen",
        symbol: "mic"
      ) {
        Picker("Mikrofon", selection: $state.config.stt.inputDeviceUID) {
          Text(systemDefaultMicrophoneLabel).tag(AudioInputDeviceCatalog.systemDefaultUID)
          ForEach(audioInputDevices) { Text($0.name).tag($0.uid) }
          if state.config.stt.inputDeviceUID != AudioInputDeviceCatalog.systemDefaultUID,
            !audioInputDevices.contains(where: { $0.uid == state.config.stt.inputDeviceUID })
          {
            Text("Nicht verfügbares Mikrofon").tag(state.config.stt.inputDeviceUID)
          }
        }
        .pickerStyle(.menu)
        Text(
          "„macOS-Standard“ folgt automatisch jedem Wechsel unter Systemeinstellungen > Ton > Eingabe. Eine feste Auswahl bleibt an dieses Gerät gebunden."
        )
        .font(.caption).foregroundStyle(.secondary)
        Label(selectedMicrophoneStatus, systemImage: "mic.fill")
          .font(.caption.weight(.medium)).foregroundStyle(.secondary)
        HStack(spacing: 10) {
          Button(state.isTestingMicrophone ? "Test läuft …" : "Mikrofon 2,5 Sekunden testen") {
            state.testSelectedMicrophone()
          }.disabled(state.isTestingMicrophone)
          ProgressView(value: state.microphoneTestLevel, total: 1).frame(maxWidth: 160)
          Text(state.microphoneTestStatus).font(.caption).foregroundStyle(.secondary)
        }
      }

      SettingsCard(
        title: "Audioausgabe", subtitle: "Lautsprecher für vorgelesene Antworten",
        symbol: "hifispeaker"
      ) {
        Picker("Lautsprecher", selection: $state.config.tts.outputDeviceUID) {
          Text(systemDefaultSpeakerLabel).tag(AudioOutputDeviceCatalog.systemDefaultUID)
          ForEach(audioOutputDevices) { Text($0.name).tag($0.uid) }
          if state.config.tts.outputDeviceUID != AudioOutputDeviceCatalog.systemDefaultUID,
            !audioOutputDevices.contains(where: { $0.uid == state.config.tts.outputDeviceUID })
          {
            Text("Nicht verfügbarer Lautsprecher").tag(state.config.tts.outputDeviceUID)
          }
        }
        .pickerStyle(.menu)
        Text(
          "„macOS-Standard“ folgt automatisch AirPods, Dock, Monitor oder internen Lautsprechern. Eine feste Auswahl wird für MiddleAI bevorzugt; fällt sie weg, nutzt MiddleAI sicher den macOS-Standard."
        )
        .font(.caption).foregroundStyle(.secondary)
        Label(selectedSpeakerStatus, systemImage: "speaker.wave.2.fill")
          .font(.caption.weight(.medium)).foregroundStyle(.secondary)
      }

      HStack {
        Button {
          refreshAudioDevices()
        } label: {
          Label("Geräte neu laden", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.bordered)
        Button("Auswahl speichern") { state.applyAudioDeviceSettings() }
          .buttonStyle(.borderedProminent)
        Button("Ausgabe testen") {
          state.applyAudioDeviceSettings()
          state.testTTS()
        }.buttonStyle(.bordered)
        Spacer()
      }
      SettingsCard(
        title: "Berechtigungen", subtitle: "macOS-Zugriff für Audio und Texteingabe",
        symbol: "hand.raised"
      ) {
        Label(state.voiceStatus, systemImage: "waveform")
        HStack {
          Button("Mikrofonfreigabe öffnen") { openMicrophonePrivacySettings() }
          Button("Bedienungshilfen öffnen") { openPrivacySettings() }
        }.buttonStyle(.bordered)
      }
    }
  }

  private var speechPane: some View {
    VStack(spacing: 16) {
      SettingsCard(
        title: "Lokale Stimme", subtitle: "Keine Sprachdaten verlassen deinen Mac",
        symbol: "speaker.wave.2"
      ) {
        Toggle(
          "Antworten vorlesen",
          isOn: Binding(
            get: { state.config.tts.enabled },
            set: {
              state.config.tts.enabled = $0
              state.applySpeechSettings()
            }))
        Picker(
          "Engine",
          selection: Binding(
            get: { state.config.tts.provider },
            set: { provider in
              if provider == "voxtral_tts" && !state.voxtralLicenseAccepted {
                showsVoxtralLicenseConfirmation = true
              } else {
                state.selectTTSProvider(provider)
              }
            })
        ) {
          Text("Qwen3-TTS · natürlichstes lokales Deutsch").tag("qwen3_tts")
          Text("Mistral Voxtral TTS · lokal · nicht-kommerziell").tag("voxtral_tts")
          Text("Automatisch · flüssiges Deutsch").tag("adaptive")
          Text("Apple Deutsch · flüssigste Aussprache").tag("macos")
          Text("Supertonic 3 · natürlicherer Klang").tag("supertonic3")
          Text("PocketTTS · Kompatibilität").tag("pockettts")
          Text("Eigenes lokales Programm").tag("local_model")
        }
        .pickerStyle(.menu)
        .alert("Nicht-kommerzielle Voxtral-Lizenz", isPresented: $showsVoxtralLicenseConfirmation) {
          Button("Abbrechen", role: .cancel) {}
          Button("Bestätigen und auswählen") { state.acceptVoxtralLicenseAndSelect() }
        } message: {
          Text(
            "Ich bestätige, dass ich Voxtral ausschließlich für nicht-kommerzielle Zwecke gemäß CC BY-NC 4.0 verwende. Für geschäftliche Inhalte bleibt Qwen3-TTS die geeignete Auswahl."
          )
        }
        Text(providerDescription)
          .font(.callout)
          .foregroundStyle(.secondary)
        if state.config.tts.provider == "voxtral_tts" {
          Label(
            "Lizenzhinweis: Voxtral darf gemäß CC BY-NC 4.0 nicht für kommerzielle oder geschäftliche Zwecke verwendet werden.",
            systemImage: "exclamationmark.triangle.fill"
          )
          .font(.callout.weight(.semibold))
          .foregroundStyle(.orange)
        }

        if !state.availableTTSVoices.isEmpty {
          VStack(spacing: 8) {
            ForEach(state.availableTTSVoices) { voice in
              VoiceSelectionCard(
                voice: voice, selected: state.config.tts.voice == voice.id
              ) {
                state.selectTTSVoice(voice.id)
              }
            }
          }
        }

        if state.config.tts.provider == "macos" || state.config.tts.provider == "adaptive" {
          HStack {
            Button("Weitere Enhanced- und Premium-Stimmen laden") { openAppleVoiceSettings() }
              .buttonStyle(.bordered)
            Text("Derzeit installiert: \(state.availableTTSVoices.count)")
              .font(.caption).foregroundStyle(.secondary)
          }
        }

        HStack {
          Text("Sprechtempo").frame(width: 112, alignment: .leading).foregroundStyle(.secondary)
          Slider(value: $state.config.tts.rate, in: 0.78...1.22)
          Text(state.config.tts.rate, format: .number.precision(.fractionLength(2)))
            .monospacedDigit().frame(width: 36)
        }
      }

      SettingsCard(
        title: "Lange Antworten", subtitle: "Die vollständige Antwort bleibt sichtbar",
        symbol: "text.badge.minus"
      ) {
        Picker("Vorlesen", selection: $state.config.spokenResponseMode) {
          Text("Lokal zusammenfassen, wenn die Antwort lang ist").tag("smart_summary")
          Text("Immer vollständig vorlesen").tag("full")
          Text("Nur den ersten Abschnitt vorlesen").tag("first_paragraph")
        }
        .pickerStyle(.menu)
        if state.config.spokenResponseMode == "smart_summary" {
          Stepper(
            "Ab \(state.config.spokenResponseThreshold) Zeichen zusammenfassen",
            value: $state.config.spokenResponseThreshold, in: 500...2_000, step: 100)
          Stepper(
            "Kurzfassung mit höchstens \(state.config.spokenResponseMaximumWords) Wörtern",
            value: $state.config.spokenResponseMaximumWords, in: 60...180, step: 10)
          Text(
            "Apple Intelligence erstellt die Kurzfassung vollständig lokal. Wenn das Modell nicht bereit ist, verwendet MiddleAI eine lokale extraktive Kurzfassung."
          )
          .font(.caption).foregroundStyle(.secondary)
        }
      }

      SettingsCard(
        title: "Lokale Modellbibliothek",
        subtitle: "Downloads, Speicherbedarf und Verfügbarkeit auf diesem Mac",
        symbol: "internaldrive"
      ) {
        VStack(spacing: 9) {
          ForEach(state.ttsModelStatuses) { model in
            TTSModelStatusRow(
              model: model,
              selected: TTSModelLibrary.modelID(for: state.config.tts.provider) == model.id,
              onRepair: { state.repairTTSModel(model) },
              onDelete: { ttsModelToDelete = model })
          }
        }
        Text(
          "MiddleAI prüft erwartete Artefakte, exakte Revision, Laufzeit und den letzten erfolgreichen Modellstart. Modellgrößen sind gerundet; beim Entpacken kann vorübergehend mehr Speicher nötig sein."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        HStack {
          Button {
            state.prepareTTSModel()
          } label: {
            Label("Ausgewähltes Modell laden oder prüfen", systemImage: "arrow.down.circle")
          }
          .buttonStyle(.bordered)
          Button {
            state.refreshTTSModelStatuses()
          } label: {
            Label("Status aktualisieren", systemImage: "arrow.clockwise")
          }
          .buttonStyle(.borderless)
        }
      }
      .alert(item: $ttsModelToDelete) { model in
        Alert(
          title: Text("\(model.title) löschen?"),
          message: Text(
            "Die heruntergeladenen Modelldaten werden in den Papierkorb verschoben. Ist das Modell ausgewählt, wechselt MiddleAI vorher auf die macOS-Stimme. Du kannst das Modell später erneut laden."
          ),
          primaryButton: .destructive(Text("In Papierkorb")) {
            state.deleteTTSModel(model)
          },
          secondaryButton: .cancel(Text("Abbrechen")))
      }

      HStack {
        Button("Hörprobe") { state.testTTS() }.buttonStyle(.bordered)
        Button("Änderungen anwenden") { state.applySpeechSettings() }
          .buttonStyle(.borderedProminent)
        Spacer()
        Text(state.ttsStatus).font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private var voicePane: some View {
    VStack(spacing: 16) {
      SettingsCard(
        title: "Lokale Spracherkennung",
        subtitle: "Parakeet TDT v3 · Sprache zu Text · vollständig auf diesem Mac",
        symbol: "waveform.badge.mic"
      ) {
        HStack(alignment: .top, spacing: 12) {
          Image(systemName: "cpu")
            .font(.title2)
            .foregroundStyle(Color.accentColor)
            .frame(width: 30)
          VStack(alignment: .leading, spacing: 4) {
            Text("Parakeet TDT 0.6B v3").font(.callout.weight(.semibold))
            Text(
              "Mehrsprachiges Modell mit rund 600 Millionen Parametern. MiddleAI lädt die Core-ML-Dateien einmalig und führt Encoder und Decoder anschließend vollständig lokal aus. Die Aufnahme wird intern auf 16 kHz normalisiert, nur im Arbeitsspeicher verarbeitet und nicht gespeichert."
            )
            .font(.caption).foregroundStyle(.secondary)
          }
        }
        Divider()
        Picker("Sprachmodus", selection: $state.config.stt.language) {
          Text("Deutsch · empfohlen").tag("de")
          Text("Mehrsprachig · automatisch").tag("auto")
        }
        .pickerStyle(.menu)
        Text(
          state.config.stt.language == "de"
            ? "Deutsch ist kein zweites Modell, sondern ein Schutzfilter im Decoder. Er verhindert vor allem Ausreißer in andere Schriftsysteme. Deutsche Sätze, Namen und englische Fachbegriffe mit lateinischen Buchstaben bleiben möglich."
            : "Mehrsprachig deaktiviert den Schriftfilter. Nutze das nur, wenn du regelmäßig ganze Passagen in Sprachen mit anderen Schriftsystemen diktierst; für deutsches Diktat ist dieser Modus meist weniger stabil."
        )
        .font(.caption).foregroundStyle(.secondary)
        Picker("Encoder", selection: $state.config.stt.encoderPrecision) {
          Text("Int8 · beste Erkennung").tag("int8")
          Text("Int4 · kompakter").tag("int4")
        }
        .pickerStyle(.segmented)
        Text(
          "Der Encoder wandelt das Audiosignal in Merkmale für den Textdecoder um. Int8 ist die Qualitätsvorgabe und bereits heruntergeladen. Int4 spart Modell- und Arbeitsspeicher, kann die Erkennung schwieriger Namen aber etwas verschlechtern und wird beim ersten Wechsel separat geladen."
        )
        .font(.caption).foregroundStyle(.secondary)
        Picker("Beschleunigung", selection: $state.config.stt.computeMode) {
          Text("Automatisch · empfohlen").tag("efficient")
          Text("CPU + GPU · kompatibel").tag("fast")
        }
        .pickerStyle(.segmented)
        Text(
          "Automatisch lässt Core ML die passende Kombination aus CPU, GPU und Neural Engine wählen. CPU + GPU schließt die Neural Engine aus und ist nur als Kompatibilitätsoption sinnvoll, wenn die automatische Ausführung auf einem bestimmten Mac Probleme verursacht."
        )
        .font(.caption).foregroundStyle(.secondary)
        Picker("Lange Diktate", selection: $state.config.stt.longFormMode) {
          Text("Genauer · empfohlen").tag("accurate")
          Text("Schneller").tag("fast")
        }
        .pickerStyle(.segmented)
        Text(
          "Diese Einstellung greift erst bei längeren Aufnahmen. „Genauer“ prüft am Anfang mehrere Segmentierungswege und reduziert ausgelassene oder doppelte Wörter an Übergängen. „Schneller“ verwendet nur einen Weg und benötigt weniger Rechenzeit."
        )
        .font(.caption).foregroundStyle(.secondary)
        Label(
          "Änderungen gelten nach „STT-Einstellungen anwenden“ für die nächste Aufnahme. Ein Wechsel der Encoder-Stufe kann beim ersten Mal einen Modelldownload auslösen.",
          systemImage: "info.circle"
        )
        .font(.caption).foregroundStyle(.secondary)
        HStack {
          Button("STT-Einstellungen anwenden") { state.applySTTSettings() }
            .buttonStyle(.borderedProminent)
          Spacer()
          Text(state.sttStatus).font(.caption).foregroundStyle(.secondary)
        }
      }

      SettingsCard(
        title: "Aktivierungstasten", subtitle: "Lege für jeden Sprachmodus eine eigene Taste fest",
        symbol: "keyboard"
      ) {
        ActivationKeyPickerRow(
          title: "Diktat", detail: "Erkannten Text ins gerade aktive Feld einfügen",
          selection: ActivationKeyChoice(rawValue: state.config.hotkeys.dictation) ?? .leftOption
        ) { state.setActivationKey($0, for: .dictation) }
        Divider()
        ActivationKeyPickerRow(
          title: "MiddleAI", detail: "Gesprochene Anfrage an den gewählten KI-Anbieter senden",
          selection: ActivationKeyChoice(rawValue: state.config.hotkeys.assistant) ?? .rightOption
        ) { state.setActivationKey($0, for: .assistant) }
        Divider()
        HStack(alignment: .top) {
          Label(
            "Die MiddleAI-Taste stoppt auch eine laufende Antwort oder Sprachausgabe.",
            systemImage: "stop.circle"
          )
          .font(.caption).foregroundStyle(.secondary)
          Spacer()
          Button("Standard wiederherstellen") { state.resetActivationKeys() }
            .buttonStyle(.borderless)
        }
        Text(
          "Kurz drücken aktiviert den freihändigen Modus. Gedrückthalten und Loslassen funktioniert ebenfalls. Command- und Umschalttasten können mit Tastenkürzeln anderer Apps kollidieren; die beiden Optionstasten bleiben die empfohlene Belegung."
        )
        .font(.caption).foregroundStyle(.secondary)
      }

      SettingsCard(
        title: "Diktat-Nachbearbeitung", subtitle: state.dictationPolishingStatus,
        symbol: "text.badge.checkmark"
      ) {
        Toggle(
          "Füllwörter und Versprecher lokal glätten",
          isOn: Binding(
            get: { state.config.dictation.polishWithLocalAI },
            set: { state.setDictationPolishing($0) }))
        Text("Bedeutung, Namen, Zahlen, Fachbegriffe und Anrede bleiben erhalten.")
          .font(.caption).foregroundStyle(.secondary)
        Divider()
        Toggle(
          "Gesprochene Formatierungsbefehle in ausgewählten Apps umsetzen",
          isOn: Binding(
            get: { state.config.dictation.smartFormatting },
            set: { state.setDictationSmartFormatting($0) }))
        Text(
          "MiddleAI erkennt eindeutige Hinweise wie „neue Zeile“, „neuer Absatz“, „in Anführungsstrichen“, „Aufzählung … Punkt eins …“, „1. … zweitens … drittens …“ und „nummerierte Liste“. Der normale Wortlaut wird nicht eigenständig umstrukturiert."
        )
        .font(.caption).foregroundStyle(.secondary)
        VStack(spacing: 7) {
          ForEach(formattingApplicationOptions) { application in
            FormattingApplicationRow(
              application: application,
              enabled: state.isDictationFormattingEnabled(
                for: application.bundleIdentifier),
              onToggle: {
                state.setDictationFormattingApplication(
                  application.bundleIdentifier, enabled: $0)
              },
              onRemove: application.isBuiltIn
                ? nil
                : {
                  state.setDictationFormattingApplication(
                    application.bundleIdentifier, enabled: false)
                })
          }
        }
        HStack {
          Button {
            chooseFormattingApplication()
          } label: {
            Label("Anwendung hinzufügen …", systemImage: "plus.app")
          }
          .buttonStyle(.bordered)
          Spacer()
          Text("Erkennung über Bundle-ID")
            .font(.caption2).foregroundStyle(.tertiary)
        }
        Text(
          "Ausgewählte Apps erhalten Klartext, Rich Text und HTML für Absätze und Listen. Nicht ausgewählte Anwendungen bekommen das Diktat unverändert als Klartext."
        )
        .font(.caption).foregroundStyle(.secondary)
      }

    }
  }

  private var intelligencePane: some View {
    VStack(spacing: 16) {
      SettingsCard(
        title: "Was macht dieser Bereich?",
        subtitle: "MiddleAI entscheidet hier nur, welche Unterhaltung weitergeführt wird",
        symbol: "questionmark.circle"
      ) {
        VStack(alignment: .leading, spacing: 12) {
          IntelligenceStep(
            number: "1", title: "Du stellst eine Frage",
            detail: "MiddleAI vergleicht sie lokal mit deinen letzten Unterhaltungen.")
          IntelligenceStep(
            number: "2", title: "MiddleAI wählt den passenden Chat",
            detail:
              "Eine Folgefrage bleibt im aktuellen Thema. Ein neues Thema bekommt einen neuen Chat."
          )
          IntelligenceStep(
            number: "3", title: "Der gewählte Anbieter erstellt die Antwort",
            detail:
              "Das hier eingestellte Routing-Modell beantwortet niemals deine Frage und ersetzt den Antwortanbieter nicht."
          )
        }
        Divider()
        HStack(alignment: .top, spacing: 10) {
          Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
          VStack(alignment: .leading, spacing: 3) {
            Text("Empfehlung für deine Nutzung").font(.callout.weight(.semibold))
            Text(
              "Nutze Hybrid mit Apple Intelligence. Wenn Apple Intelligence nicht bereit ist, arbeitet MiddleAI automatisch mit den eingebauten Regeln weiter."
            )
            .font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          Button("Empfehlung verwenden") { state.useRecommendedRouting() }
            .buttonStyle(.borderedProminent)
        }
      }

      SettingsCard(
        title: "Chat-Auswahl", subtitle: "Ordnet Folgefragen automatisch dem passenden Thema zu",
        symbol: "arrow.triangle.branch"
      ) {
        Picker("Strategie", selection: $state.config.routing.strategy) {
          Text("Hybrid · empfohlen").tag("hybrid")
          Text("Einfach · nur Zeit und Begriffe").tag("heuristic")
        }
        .pickerStyle(.segmented)
        Text(routingDescription)
          .font(.caption).foregroundStyle(.secondary)
        HStack {
          Text("Folgefrage bis").frame(width: 112, alignment: .leading).foregroundStyle(.secondary)
          TextField(
            "Sekunden", value: $state.config.routing.continuationTimeoutSeconds,
            format: .number
          )
          .textFieldStyle(.roundedBorder)
          Text("Sekunden").foregroundStyle(.secondary)
        }
        Text(
          "Innerhalb dieses Zeitraums behandelt MiddleAI kurze Anschlüsse wie „Und Hannover?“ bevorzugt als Folgefrage. 300 Sekunden sind ein guter Standardwert."
        )
        .font(.caption).foregroundStyle(.secondary)
      }

      SettingsCard(
        title: "KI für die Chat-Auswahl",
        subtitle: "Wähle bewusst zwischen Apple Intelligence und einem eigenen lokalen Server",
        symbol: "cpu"
      ) {
        Picker(
          "Quelle",
          selection: Binding(
            get: { state.intelligenceProviderChoice },
            set: { state.selectIntelligenceProvider($0) })
        ) {
          Text("Apple Intelligence · empfohlen").tag("apple")
          Text("Ollama · eigener lokaler Server").tag("ollama")
          Text("llama.cpp · lokaler /v1-Server").tag("llama_cpp")
          Text("Nur MiddleAI-Regeln · ohne KI-Modell").tag("rules")
        }
        .pickerStyle(.menu)
        Text(intelligenceProviderDescription)
          .font(.caption).foregroundStyle(.secondary)

        if ["ollama", "llama_cpp"].contains(state.intelligenceProviderChoice) {
          Divider()
          SettingsField(
            title: "Server-Endpunkt",
            prompt: state.intelligenceProviderChoice == "llama_cpp"
              ? "http://127.0.0.1:18881" : "http://127.0.0.1:11434",
            text: $state.config.localLLM.url)
          SettingsField(
            title: "Modell-ID oder Alias",
            prompt: state.intelligenceProviderChoice == "llama_cpp" ? "z. B. router" : "qwen3:4b",
            text: $state.config.localLLM.model)
          Text(localServerHelp)
            .font(.caption).foregroundStyle(.secondary)
        }
        Divider()
        Label(
          "Diese Auswahl betrifft nur mehrdeutige Chat-Zuordnungen. Antworten erzeugt weiterhin \(state.config.assistantProviderTitle). Diktatglättung stellst du unter „Spracheingabe“ ein; Kurzfassungen unter „Sprachausgabe“.",
          systemImage: "lock.shield"
        )
        .font(.caption).foregroundStyle(.secondary)
        HStack {
          Button(
            state.intelligenceProviderChoice == "apple"
              ? "Verfügbarkeit prüfen" : "Verbindung prüfen"
          ) {
            state.testLocalRouter()
          }
          .buttonStyle(.bordered)
          .disabled(state.intelligenceProviderChoice == "rules")
          Button("Einstellungen speichern") { state.saveIntelligenceSettings() }
            .buttonStyle(.borderedProminent)
          Spacer()
        }
        Label(state.intelligenceStatus, systemImage: "info.circle")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private var helpPane: some View {
    VStack(spacing: 16) {
      SettingsCard(
        title: "Antwortanbieter einrichten",
        subtitle: "OpenWebUI, OpenAI Platform oder OpenRouter",
        symbol: "point.3.connected.trianglepath.dotted"
      ) {
        HelpStep(
          number: "1", title: "Anbieter wählen",
          detail:
            "OpenWebUI nutzt deinen eigenen Server. OpenAI und OpenRouter benötigen jeweils einen API-Schlüssel des Anbieters."
        )
        HelpStep(
          number: "2", title: "Modelle laden",
          detail:
            "Unter Verbindung authentifizieren. MiddleAI liest anschließend die für den Schlüssel sichtbaren Modell-IDs direkt vom Anbieter aus."
        )
        HelpStep(
          number: "3", title: "Modell speichern",
          detail:
            "Wähle ein Modell aus der Liste oder trage eine unterstützte ID manuell ein. Zugangsdaten bleiben ausschließlich im macOS-Schlüsselbund."
        )
        Label(
          "Ein ChatGPT-Abonnement ist getrennt von der nutzungsbasierten OpenAI Platform API. Bei OpenRouter gelten die Preise und Datenschutzregeln der dort gewählten Modellroute.",
          systemImage: "info.circle"
        )
        .font(.caption).foregroundStyle(.secondary)
      }

      SettingsCard(
        title: "Audiogeräte",
        subtitle: "Automatisch dem Mac folgen oder Geräte fest auswählen",
        symbol: "hifispeaker.2"
      ) {
        HelpStep(
          number: "1", title: "macOS-Standard",
          detail: "Folgt automatisch einem Wechsel auf AirPods, Dock, Monitor oder interne Geräte.")
        HelpStep(
          number: "2", title: "Festes Gerät",
          detail:
            "MiddleAI verwendet die Core-Audio-UID des gewählten Mikrofons oder Lautsprechers, ohne den globalen macOS-Ausgang umzuschalten."
        )
        HelpStep(
          number: "3", title: "Sicherer Rückfall",
          detail:
            "Ist ein fest gewählter Lautsprecher nicht mehr erreichbar, wird die Ausgabe über den aktuellen macOS-Standard versucht."
        )
      }

      SettingsCard(
        title: "Systemanforderungen", subtitle: "Unterstützte Macs und empfohlene Ausstattung",
        symbol: "desktopcomputer"
      ) {
        RequirementRow(symbol: "apple.logo", title: "Mac", value: "Apple Silicon · M1 oder neuer")
        Divider()
        RequirementRow(symbol: "macwindow", title: "macOS", value: "macOS 14 Sonoma oder neuer")
        Divider()
        RequirementRow(
          symbol: "memorychip", title: "Arbeitsspeicher",
          value: "8 GB Minimum · 16 GB für Qwen · 24 GB für Voxtral empfohlen")
        Divider()
        RequirementRow(
          symbol: "internaldrive", title: "Freier Speicher",
          value: "5 GB für ein kompaktes Setup · 12 bis 15 GB für alle Modelle")
        Divider()
        RequirementRow(
          symbol: "network", title: "Netzwerk",
          value: "Erster Modelldownload und Verbindung zum Antwortanbieter")
        Text(
          "Intel-Macs werden vom aktuellen App-Paket nicht unterstützt. Diktatglättung und intelligente Kurzfassungen über Apple Intelligence benötigen macOS 26 und ein dafür freigegebenes Gerät; MiddleAI verwendet andernfalls lokale Rückfallverfahren."
        )
        .font(.caption).foregroundStyle(.secondary)
      }

      SettingsCard(
        title: "Auf einen anderen Mac übertragen",
        subtitle: "Die App lässt sich kopieren, richtet aber jeden Benutzer separat ein",
        symbol: "arrow.right.doc.on.clipboard"
      ) {
        HelpStep(
          number: "1", title: "MiddleAI.app nach Programme kopieren",
          detail: "Das App-Paket enthält die Swift-Laufzeit und benötigt weder Xcode noch Homebrew."
        )
        HelpStep(
          number: "2", title: "Beim ersten Start freigeben",
          detail:
            "Der aktuelle Entwicklungsbuild ist ad-hoc signiert. Gatekeeper kann deshalb Rechtsklick und „Öffnen“ verlangen."
        )
        HelpStep(
          number: "3", title: "Verbindung und Berechtigungen einrichten",
          detail:
            "API- oder Serverzugänge, Mikrofon und Bedienungshilfen werden aus Sicherheitsgründen nicht mitkopiert."
        )
        HelpStep(
          number: "4", title: "Sprachmodelle laden",
          detail:
            "STT und TTS laufen anschließend lokal. Den Downloadstatus findest du unter Sprachausgabe."
        )
        Label(
          "Für eine reguläre Verteilung sollte die App mit einer Apple Developer ID signiert und notarisiert werden.",
          systemImage: "checkmark.shield"
        )
        .font(.caption).foregroundStyle(.secondary)
      }

      SettingsCard(
        title: "Formatierungsbefehle diktieren",
        subtitle: "In den ausgewählten Apps wird gesprochene Struktur direkt umgesetzt",
        symbol: "text.alignleft"
      ) {
        HelpStep(
          number: "1", title: "Zeilen und Absätze",
          detail:
            "„Neue Zeile“ erzeugt einen einfachen Umbruch. „Neuer Absatz“ erzeugt einen Absatzabstand."
        )
        HelpStep(
          number: "2", title: "Anführungszeichen",
          detail:
            "Sage etwa „in Anführungsstrichen Projekt Apollo“ oder „Anführungszeichen auf … Anführungszeichen zu“."
        )
        HelpStep(
          number: "3", title: "Aufzählungen",
          detail:
            "Sage „Aufzählung, Punkt eins …, nächster Punkt …“ oder natürlicher „Aufzählung: 1. …, zweitens … und drittens …“. Für eine geordnete Liste beginne mit „nummerierte Liste“."
        )
        HelpStep(
          number: "4", title: "Bewusst konservativ",
          detail:
            "MiddleAI formatiert nur eindeutige Befehle. Normale Aussagen wie „Die neue Zeile ist rot“ bleiben unverändert."
        )
        Label(
          "Die Auswertung erfolgt lokal nach der optionalen Diktatglättung. Welche Apps formatiert werden, legst du unter Spracheingabe fest.",
          systemImage: "lock.shield"
        )
        .font(.caption).foregroundStyle(.secondary)
      }

      SettingsCard(
        title: "Speicherbedarf", subtitle: "Gerundete Größen der aktuellen Modellvarianten",
        symbol: "externaldrive.badge.icloud"
      ) {
        RequirementRow(symbol: "waveform", title: "Parakeet STT", value: "etwa 1 GB")
        RequirementRow(
          symbol: "speaker.wave.2", title: "Supertonic 3", value: "etwa 0,2 bis 0,4 GB")
        RequirementRow(
          symbol: "sparkles", title: "Qwen3-TTS", value: "etwa 2,8 GB einschließlich Laufzeit")
        RequirementRow(
          symbol: "waveform.badge.magnifyingglass", title: "Voxtral TTS",
          value: "etwa 3 GB einschließlich Laufzeit")
        Text(
          "Voxtral steht unter CC BY-NC 4.0 und darf nicht für kommerzielle oder geschäftliche Zwecke verwendet werden."
        )
        .font(.caption.weight(.semibold)).foregroundStyle(.orange)
      }

      SettingsCard(
        title: "Datenschutz", subtitle: "Welche Daten den Mac verlassen",
        symbol: "lock.shield"
      ) {
        Label(
          "Mikrofonaudio, STT und TTS bleiben lokal auf dem Mac.",
          systemImage: "checkmark.circle.fill"
        )
        .foregroundStyle(.green)
        Label(
          "Nur fertige Anfragen im MiddleAI-Modus werden an den eingestellten Antwortanbieter übertragen.",
          systemImage: "server.rack")
        Label(
          "Diktate für aktive Textfelder werden niemals an den Antwortanbieter gesendet.",
          systemImage: "text.cursor")
        Divider()
        HStack {
          Text("Automatisch aufbewahren")
            .frame(maxWidth: .infinity, alignment: .leading)
          Picker(
            "Automatisch aufbewahren",
            selection: Binding(
              get: { state.config.privacy.localCacheRetentionDays },
              set: { value in
                state.config.privacy.localCacheRetentionDays = value
                state.savePrivacySettings()
              })
          ) {
            Text("30 Tage").tag(30)
            Text("90 Tage").tag(90)
            Text("1 Jahr").tag(365)
            Text("Dauerhaft").tag(0)
          }
          .labelsHidden()
          .pickerStyle(.menu)
        }
        Text(
          "MiddleAI bereinigt beim Start nur seine lokale Routing-Kopie. Serverseitige Chats beim Anbieter sind davon nicht betroffen."
        )
        .font(.caption2).foregroundStyle(.secondary)
        HStack {
          VStack(alignment: .leading, spacing: 3) {
            Text("Lokaler Gesprächscache").font(.callout.weight(.medium))
            Text(state.localCacheStatus).font(.caption).foregroundStyle(.secondary)
            Text(
              "Das Löschen betrifft nur MiddleAI auf diesem Mac. Serverseitige Unterhaltungen bleiben erhalten."
            )
            .font(.caption2).foregroundStyle(.secondary)
          }
          Spacer()
          Menu("Bereinigen") {
            Button("Älter als 30 Tage") { state.purgeLocalHistory(olderThanDays: 30) }
            Button("Älter als 90 Tage") { state.purgeLocalHistory(olderThanDays: 90) }
            Divider()
            Button("Gesamten lokalen Cache löschen", role: .destructive) {
              confirmsCacheDeletion = true
            }
          }
        }
      }
    }
    .confirmationDialog(
      "Lokalen MiddleAI-Cache löschen?",
      isPresented: $confirmsCacheDeletion,
      titleVisibility: .visible
    ) {
      Button("Lokalen Cache löschen", role: .destructive) { state.clearLocalHistory() }
      Button("Abbrechen", role: .cancel) {}
    } message: {
      Text(
        "Serverseitige Unterhaltungen werden nicht gelöscht. Nur die lokale Routing-Kopie auf diesem Mac wird entfernt."
      )
    }
  }

  private var routingDescription: String {
    switch state.config.routing.strategy {
    case "heuristic":
      return
        "Der einfache Modus berücksichtigt Zeitabstand, wiederkehrende Begriffe und typische Anschlusswörter. Er ist schnell, kann bei ähnlichen Themen aber ungenauer sein."
    default:
      return
        "Hybrid kombiniert Zeitabstand, Begriffe und einen lokalen Ähnlichkeitsvergleich. Das ist genauer und läuft auch ohne Ollama vollständig lokal."
    }
  }

  private var systemDefaultMicrophoneLabel: String {
    let defaultName = audioInputDevices.first(where: \AudioInputDevice.isSystemDefault)?.name
    return defaultName.map { "macOS-Standard · \($0)" } ?? "macOS-Standard"
  }

  private var systemDefaultSpeakerLabel: String {
    let defaultName = audioOutputDevices.first(where: \.isSystemDefault)?.name
    return defaultName.map { "macOS-Standard · \($0)" } ?? "macOS-Standard"
  }

  private var selectedSpeakerStatus: String {
    if state.config.tts.outputDeviceUID == AudioOutputDeviceCatalog.systemDefaultUID {
      return "Aktiv: \(systemDefaultSpeakerLabel)"
    }
    if let device = audioOutputDevices.first(where: { $0.uid == state.config.tts.outputDeviceUID })
    {
      return "Fest ausgewählt: \(device.name)"
    }
    return "Der gespeicherte Lautsprecher ist derzeit nicht angeschlossen"
  }

  private var assistantModelBinding: Binding<String> {
    Binding(get: { state.config.assistantModel }, set: { state.config.assistantModel = $0 })
  }

  private var answerProviderDescription: String {
    switch state.config.assistant.provider {
    case "openai":
      return
        "Direkter Zugriff auf die OpenAI Platform. Abrechnung und Datenverarbeitung erfolgen über dein OpenAI-API-Konto; ein ChatGPT-Abo enthält kein API-Guthaben."
    case "openrouter":
      return
        "Ein API-Schlüssel für viele Modellanbieter. Die Modellliste berücksichtigt nach Anmeldung deine OpenRouter-Freigaben und Datenschutzeinstellungen."
    default:
      return
        "Verwendet deinen eigenen OpenWebUI-Arbeitsbereich einschließlich dessen Werkzeuge, Websuche und serverseitiger Chat-Historie."
    }
  }

  private func refreshAudioDevices() {
    audioInputDevices = AudioInputDeviceCatalog.availableDevices()
    audioOutputDevices = AudioOutputDeviceCatalog.availableDevices()
  }

  private var selectedMicrophoneStatus: String {
    if state.config.stt.inputDeviceUID == AudioInputDeviceCatalog.systemDefaultUID {
      return "Aktiv: \(systemDefaultMicrophoneLabel)"
    }
    if let device = audioInputDevices.first(where: { $0.uid == state.config.stt.inputDeviceUID }) {
      return "Fest ausgewählt: \(device.name)"
    }
    return "Das gespeicherte Mikrofon ist derzeit nicht angeschlossen"
  }

  private var intelligenceProviderDescription: String {
    switch state.intelligenceProviderChoice {
    case "apple":
      return
        "Apple Intelligence läuft über das macOS-Systemmodell, benötigt keinen separaten Download in MiddleAI und bekommt nur dann Kontext, wenn Hybridregeln bei der Chat-Auswahl uneinig sind. Nicht verfügbar auf diesem Mac? Dann bleiben die eingebauten Regeln aktiv."
    case "ollama":
      return
        "Ollama stellt ein selbst gewähltes lokales Modell bereit. MiddleAI verwendet dessen lokale /v1-API ausschließlich als Entscheidungshilfe für mehrdeutige Chat-Zuordnungen."
    case "llama_cpp":
      return
        "llama.cpp wird über die lokalen Endpunkte /v1/models und /v1/chat/completions angesprochen. Für deinen Mac ist http://127.0.0.1:18881 voreingestellt. MiddleAI startet oder lädt den Server selbst nicht."
    default:
      return
        "MiddleAI nutzt nur Zeitabstand, Begriffe und lokale Ähnlichkeit. Das braucht weder Apple Intelligence noch einen Modellserver und ist der robusteste Rückfallmodus."
    }
  }

  private var localServerHelp: String {
    if state.intelligenceProviderChoice == "llama_cpp" {
      return
        "Der Server muss /v1/models und /v1/chat/completions anbieten. Bei einem llama.cpp-Router mit automatischem Laden trägst du als Modell-ID den dort konfigurierten Modellalias ein. Bleibt /v1/models leer, ist der Server zwar erreichbar, aber noch kein Modell bekannt."
    }
    return
      "Ollama muss laufen und das Modell muss bereits mit „ollama pull“ geladen sein. Der Standardendpunkt ist http://127.0.0.1:11434; MiddleAI ergänzt /v1 automatisch."
  }

  private var formattingApplicationOptions: [FormattingApplicationOption] {
    let builtIns: [(String, String, String)] = [
      ("com.microsoft.Word", "Microsoft Word", "doc.text"),
      ("com.microsoft.Powerpoint", "Microsoft PowerPoint", "rectangle.on.rectangle"),
      ("com.microsoft.Outlook", "Microsoft Outlook", "envelope"),
      ("ch.protonmail.desktop", "Proton Mail", "lock.shield"),
    ]
    let builtInIDs = Set(builtIns.map { $0.0.lowercased() })
    let defaults = builtIns.map {
      formattingApplicationOption(
        bundleIdentifier: $0.0, fallbackName: $0.1, symbol: $0.2, isBuiltIn: true)
    }
    let custom = state.config.dictation.formattingApplications
      .filter { !builtInIDs.contains($0.lowercased()) }
      .map {
        formattingApplicationOption(
          bundleIdentifier: $0, fallbackName: $0, symbol: "app", isBuiltIn: false)
      }
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    return defaults + custom
  }

  private func formattingApplicationOption(
    bundleIdentifier: String, fallbackName: String, symbol: String, isBuiltIn: Bool
  ) -> FormattingApplicationOption {
    let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    let bundle = url.flatMap(Bundle.init(url:))
    let name =
      (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
      ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
      ?? fallbackName
    let icon = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
    return FormattingApplicationOption(
      bundleIdentifier: bundleIdentifier, name: name, symbol: symbol,
      icon: icon, isBuiltIn: isBuiltIn)
  }

  private func chooseFormattingApplication() {
    let panel = NSOpenPanel()
    panel.title = "Anwendung für Diktatformatierung auswählen"
    panel.message = "MiddleAI erkennt die Anwendung lokal anhand ihrer Bundle-ID."
    panel.prompt = "Hinzufügen"
    panel.allowedContentTypes = [.applicationBundle]
    panel.allowsMultipleSelection = false
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
    guard panel.runModal() == .OK, let url = panel.url else { return }
    guard let bundleIdentifier = Bundle(url: url)?.bundleIdentifier, !bundleIdentifier.isEmpty
    else {
      state.lastError = "Die ausgewählte Anwendung besitzt keine lesbare Bundle-ID."
      return
    }
    state.setDictationFormattingApplication(bundleIdentifier, enabled: true)
  }

  private var providerDescription: String {
    switch state.config.tts.provider {
    case "qwen3_tts":
      return
        "Qwen3-TTS VoiceDesign erzeugt eine flüssige weibliche Stimme mit neutralem Standarddeutsch und natürlicher Betonung vollständig lokal über Apple MLX. MiddleAI verwendet jetzt die stabile 4-Bit-Version mit etwa 2,3 GB."
    case "voxtral_tts":
      return
        "Voxtral ist Mistrals besonders natürliche lokale 4-Bit-Stimme mit etwa 2,5 GB Modelldaten. Wichtig: Die Modelllizenz CC BY-NC 4.0 erlaubt keine kommerzielle Nutzung. Für geschäftliche Inhalte ist Qwen3-TTS die sichere Auswahl."
    case "adaptive":
      return
        "Empfohlen: Kurze Antworten nutzt MiddleAI mit der natürlicheren lokalen Stimme. Bei längeren Texten, Zahlen und Fachbegriffen wechselt es automatisch zur zuverlässigeren deutschen Apple-Stimme."
    case "macos":
      return
        "Apple-Stimmen sprechen Zahlen, Satzmelodie und deutsches Fachvokabular am zuverlässigsten. Enhanced- und Premium-Stimmen werden nach dem Download automatisch bevorzugt."
    case "supertonic3":
      return
        "Supertonic läuft als Core-ML-Modell lokal. MiddleAI erzeugt die Antwort jetzt in einem kontinuierlichen Durchlauf und bereitet englische Produktnamen phonetisch vor."
    case "pockettts":
      return
        "PocketTTS bleibt als lokale Alternative verfügbar, kann bei Deutsch aber einen hörbaren Akzent haben."
    default:
      return
        "MiddleAI startet das angegebene lokale Programm und übergibt ausschließlich den zu sprechenden Text."
    }
  }

  private func saveConnection() {
    do {
      try state.save(password: password)
      saveMessage = "Gespeichert. Verbindung wird geprüft …"
      Task {
        await state.connectAndServe()
        saveMessage =
          state.status == "Connected"
          ? "Gespeichert und verbunden" : state.lastError
      }
    } catch { saveMessage = error.localizedDescription }
  }

  private func selectAssistantProvider(_ provider: String) {
    guard state.config.assistant.provider != provider else { return }
    state.config.assistant.provider = provider
    password = ""
    state.providerModels = []
    state.providerModelStatus = "Bitte für diesen Anbieter authentifizieren"
    saveMessage = ""
  }

  private func openAppleVoiceSettings() {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent"
      )
    else { return }
    NSWorkspace.shared.open(url)
  }

  private func openPrivacySettings() {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    else { return }
    NSWorkspace.shared.open(url)
  }

  private func openMicrophonePrivacySettings() {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    else { return }
    NSWorkspace.shared.open(url)
  }
}
