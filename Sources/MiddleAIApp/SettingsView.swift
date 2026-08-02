import AppKit
import MiddleAICore
import SwiftUI

enum MiddleAISettingsPane: String, CaseIterable, Identifiable {
  case connection
  case speech
  case voice
  case intelligence
  case help

  var id: String { rawValue }
  var title: String {
    switch self {
    case .connection: return "Verbindung"
    case .speech: return "Sprachausgabe"
    case .voice: return "Spracheingabe"
    case .intelligence: return "Intelligenz"
    case .help: return "Hilfe"
    }
  }
  var subtitle: String {
    switch self {
    case .connection: return "OpenWebUI und Modell"
    case .speech: return "Stimmen und Kurzfassungen"
    case .voice: return "Aktivierungstasten und Diktat"
    case .intelligence: return "Routing und lokale Modelle"
    case .help: return "Installation und Anforderungen"
    }
  }
  var symbol: String {
    switch self {
    case .connection: return "network"
    case .speech: return "speaker.wave.3"
    case .voice: return "waveform.and.mic"
    case .intelligence: return "brain.head.profile"
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
          Label(state.status, systemImage: state.status == "Connected" ? "checkmark.circle.fill" : "circle.dotted")
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
          case .speech: speechPane
          case .voice: voicePane
          case .intelligence: intelligencePane
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
      Spacer()
      Text(state.status == "Connected" ? "OpenWebUI verbunden" : "Lokal konfiguriert")
        .font(.caption.weight(.medium))
        .foregroundStyle(state.status == "Connected" ? Color.green : .secondary)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.primary.opacity(0.045), in: Capsule())
    }
  }

  private var connectionPane: some View {
    VStack(spacing: 16) {
      SettingsCard(
        title: "OpenWebUI", subtitle: "Private Verbindung zu deinem OpenWebUI-Arbeitsbereich",
        symbol: "lock.shield")
      {
        SettingsField(title: "Server", prompt: "https://chat.example.com", text: $state.config.openwebui.url)
        SettingsField(title: "Benutzer", prompt: "name@firma.de", text: $state.config.openwebui.username)
        HStack(alignment: .firstTextBaseline, spacing: 18) {
          Text("Passwort").frame(width: 112, alignment: .leading).foregroundStyle(.secondary)
          SecureField("Im macOS-Schlüsselbund gespeichert", text: $password)
            .textFieldStyle(.roundedBorder)
        }
        SettingsField(title: "Modell-ID", prompt: "model-id", text: $state.config.openwebui.model)
        Divider()
        Toggle("TLS-Zertifikate überprüfen", isOn: $state.config.openwebui.tlsVerify)
        SettingsField(
          title: "Eigene CA", prompt: "Optionaler Dateipfad",
          text: Binding(
            get: { state.config.openwebui.caFile ?? "" },
            set: { state.config.openwebui.caFile = $0.isEmpty ? nil : $0 }))
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

  private var speechPane: some View {
    VStack(spacing: 16) {
      SettingsCard(
        title: "Lokale Stimme", subtitle: "Keine Sprachdaten verlassen deinen Mac",
        symbol: "speaker.wave.2")
      {
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
            set: { state.selectTTSProvider($0) })
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
        symbol: "text.badge.minus")
      {
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
          Text("Apple Intelligence erstellt die Kurzfassung vollständig lokal. Wenn das Modell nicht bereit ist, verwendet MiddleAI eine lokale extraktive Kurzfassung.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }

      SettingsCard(
        title: "Lokale Modellbibliothek",
        subtitle: "Downloads, Speicherbedarf und Verfügbarkeit auf diesem Mac",
        symbol: "internaldrive")
      {
        VStack(spacing: 9) {
          ForEach(state.ttsModelStatuses) { model in
            TTSModelStatusRow(
              model: model,
              selected: TTSModelLibrary.modelID(for: state.config.tts.provider) == model.id,
              onDelete: { ttsModelToDelete = model })
          }
        }
        Text("Die Fortschrittswerte basieren auf dem tatsächlich belegten lokalen Speicher. Modellgrößen sind gerundet; beim Entpacken kann der benötigte Platz vorübergehend höher sein.")
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
          message: Text("Die heruntergeladenen Modelldaten werden in den Papierkorb verschoben. Ist das Modell ausgewählt, wechselt MiddleAI vorher auf die macOS-Stimme. Du kannst das Modell später erneut laden."),
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
        title: "Aktivierungstasten", subtitle: "Lege für jeden Sprachmodus eine eigene Taste fest",
        symbol: "keyboard")
      {
        ActivationKeyPickerRow(
          title: "Diktat", detail: "Erkannten Text ins gerade aktive Feld einfügen",
          selection: ActivationKeyChoice(rawValue: state.config.hotkeys.dictation) ?? .leftOption
        ) { state.setActivationKey($0, for: .dictation) }
        Divider()
        ActivationKeyPickerRow(
          title: "MiddleAI", detail: "Gesprochene Anfrage an OpenWebUI senden",
          selection: ActivationKeyChoice(rawValue: state.config.hotkeys.assistant) ?? .rightOption
        ) { state.setActivationKey($0, for: .assistant) }
        Divider()
        HStack(alignment: .top) {
          Label("Die MiddleAI-Taste stoppt auch eine laufende Antwort oder Sprachausgabe.", systemImage: "stop.circle")
            .font(.caption).foregroundStyle(.secondary)
          Spacer()
          Button("Standard wiederherstellen") { state.resetActivationKeys() }
            .buttonStyle(.borderless)
        }
        Text("Kurz drücken aktiviert den freihändigen Modus. Gedrückthalten und Loslassen funktioniert ebenfalls. Command- und Umschalttasten können mit Tastenkürzeln anderer Apps kollidieren; die beiden Optionstasten bleiben die empfohlene Belegung.")
          .font(.caption).foregroundStyle(.secondary)
      }

      SettingsCard(
        title: "Diktat-Nachbearbeitung", subtitle: state.dictationPolishingStatus,
        symbol: "text.badge.checkmark")
      {
        Toggle(
          "Füllwörter und Versprecher lokal glätten",
          isOn: Binding(
            get: { state.config.dictation.polishWithLocalAI },
            set: { state.setDictationPolishing($0) }))
        Text("Bedeutung, Namen, Zahlen, Fachbegriffe und Anrede bleiben erhalten.")
          .font(.caption).foregroundStyle(.secondary)
        Divider()
        Toggle(
          "Gesprochene Formatierungsbefehle in unterstützten Apps umsetzen",
          isOn: Binding(
            get: { state.config.dictation.smartFormatting },
            set: { state.setDictationSmartFormatting($0) }))
        Text("MiddleAI erkennt nur eindeutige Hinweise wie „neue Zeile“, „neuer Absatz“, „in Anführungsstrichen“, „Aufzählung … nächster Punkt …“ und „nummerierte Liste“. Der normale Wortlaut wird nicht eigenständig umstrukturiert.")
          .font(.caption).foregroundStyle(.secondary)
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 7) {
          SupportedFormattingApp(name: "Microsoft Word", symbol: "doc.text")
          SupportedFormattingApp(name: "Microsoft PowerPoint", symbol: "rectangle.on.rectangle")
          SupportedFormattingApp(name: "Microsoft Outlook", symbol: "envelope")
          SupportedFormattingApp(name: "Proton Mail", symbol: "lock.shield")
        }
        Text("Word und PowerPoint erhalten zusätzlich Rich Text und HTML für Listen. Outlook und Proton Mail erhalten formatierte E-Mail-Absätze, Zeilenumbrüche, Zitate und Aufzählungen. Außerhalb dieser vier Apps wird das Diktat unverändert als Klartext eingefügt.")
          .font(.caption).foregroundStyle(.secondary)
      }

      SettingsCard(
        title: "Berechtigungen", subtitle: "Für globale Tasten und Texteingabe",
        symbol: "hand.raised")
      {
        Label(state.voiceStatus, systemImage: "waveform")
        Button("Datenschutz und Bedienungshilfen öffnen") { openPrivacySettings() }
          .buttonStyle(.bordered)
      }
    }
  }

  private var intelligencePane: some View {
    VStack(spacing: 16) {
      SettingsCard(
        title: "Was macht dieser Bereich?",
        subtitle: "MiddleAI entscheidet hier nur, welche Unterhaltung weitergeführt wird",
        symbol: "questionmark.circle")
      {
        VStack(alignment: .leading, spacing: 12) {
          IntelligenceStep(
            number: "1", title: "Du stellst eine Frage",
            detail: "MiddleAI vergleicht sie lokal mit deinen letzten Unterhaltungen.")
          IntelligenceStep(
            number: "2", title: "MiddleAI wählt den passenden Chat",
            detail: "Eine Folgefrage bleibt im aktuellen Thema. Ein neues Thema bekommt einen neuen Chat.")
          IntelligenceStep(
            number: "3", title: "OpenWebUI erstellt die Antwort",
            detail: "Das hier eingestellte Routing-Modell beantwortet niemals deine Frage und ersetzt OpenWebUI nicht.")
        }
        Divider()
        HStack(alignment: .top, spacing: 10) {
          Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
          VStack(alignment: .leading, spacing: 3) {
            Text("Empfehlung für deine Nutzung").font(.callout.weight(.semibold))
            Text("Nutze Hybrid mit Apple Intelligence. Wenn Apple Intelligence nicht bereit ist, arbeitet MiddleAI automatisch mit den eingebauten Regeln weiter.")
              .font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          Button("Empfehlung verwenden") { state.useRecommendedRouting() }
            .buttonStyle(.borderedProminent)
        }
      }

      SettingsCard(
        title: "Chat-Auswahl", subtitle: "Ordnet Folgefragen automatisch dem passenden Thema zu",
        symbol: "arrow.triangle.branch")
      {
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
            format: .number)
            .textFieldStyle(.roundedBorder)
          Text("Sekunden").foregroundStyle(.secondary)
        }
        Text("Innerhalb dieses Zeitraums behandelt MiddleAI kurze Anschlüsse wie „Und Hannover?“ bevorzugt als Folgefrage. 300 Sekunden sind ein guter Standardwert.")
          .font(.caption).foregroundStyle(.secondary)
      }

      SettingsCard(
        title: "KI für die Chat-Auswahl", subtitle: "Wähle bewusst zwischen Apple Intelligence und einem eigenen lokalen Server",
        symbol: "cpu")
      {
        Picker(
          "Quelle",
          selection: Binding(
            get: { state.intelligenceProviderChoice },
            set: { state.selectIntelligenceProvider($0) })
        ) {
          Text("Apple Intelligence · empfohlen").tag("apple")
          Text("Ollama · eigener lokaler Server").tag("ollama")
          Text("llama.cpp · OpenAI-kompatibler Server").tag("llama_cpp")
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
        Label("Diese Auswahl betrifft nur mehrdeutige Chat-Zuordnungen. Antworten erzeugt weiterhin OpenWebUI. Diktatglättung stellst du unter „Spracheingabe“ ein; Kurzfassungen unter „Sprachausgabe“.", systemImage: "lock.shield")
          .font(.caption).foregroundStyle(.secondary)
        HStack {
          Button(state.intelligenceProviderChoice == "apple" ? "Verfügbarkeit prüfen" : "Verbindung prüfen") {
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
        title: "Systemanforderungen", subtitle: "Unterstützte Macs und empfohlene Ausstattung",
        symbol: "desktopcomputer")
      {
        RequirementRow(symbol: "apple.logo", title: "Mac", value: "Apple Silicon · M1 oder neuer")
        Divider()
        RequirementRow(symbol: "macwindow", title: "macOS", value: "macOS 14 Sonoma oder neuer")
        Divider()
        RequirementRow(symbol: "memorychip", title: "Arbeitsspeicher", value: "8 GB Minimum · 16 GB für Qwen · 24 GB für Voxtral empfohlen")
        Divider()
        RequirementRow(symbol: "internaldrive", title: "Freier Speicher", value: "5 GB für ein kompaktes Setup · 12 bis 15 GB für alle Modelle")
        Divider()
        RequirementRow(symbol: "network", title: "Netzwerk", value: "Erster Modelldownload und OpenWebUI-Verbindung")
        Text("Intel-Macs werden vom aktuellen App-Paket nicht unterstützt. Diktatglättung und intelligente Kurzfassungen über Apple Intelligence benötigen macOS 26 und ein dafür freigegebenes Gerät; MiddleAI verwendet andernfalls lokale Rückfallverfahren.")
          .font(.caption).foregroundStyle(.secondary)
      }

      SettingsCard(
        title: "Auf einen anderen Mac übertragen",
        subtitle: "Die App lässt sich kopieren, richtet aber jeden Benutzer separat ein",
        symbol: "arrow.right.doc.on.clipboard")
      {
        HelpStep(number: "1", title: "MiddleAI.app nach Programme kopieren", detail: "Das App-Paket enthält die Swift-Laufzeit und benötigt weder Xcode noch Homebrew.")
        HelpStep(number: "2", title: "Beim ersten Start freigeben", detail: "Der aktuelle Entwicklungsbuild ist ad-hoc signiert. Gatekeeper kann deshalb Rechtsklick und „Öffnen“ verlangen.")
        HelpStep(number: "3", title: "Verbindung und Berechtigungen einrichten", detail: "OpenWebUI-Zugangsdaten, Mikrofon und Bedienungshilfen werden aus Sicherheitsgründen nicht mitkopiert.")
        HelpStep(number: "4", title: "Sprachmodelle laden", detail: "STT und TTS laufen anschließend lokal. Den Downloadstatus findest du unter Sprachausgabe.")
        Label("Für eine reguläre Verteilung sollte die App mit einer Apple Developer ID signiert und notarisiert werden.", systemImage: "checkmark.shield")
          .font(.caption).foregroundStyle(.secondary)
      }

      SettingsCard(
        title: "Formatierungsbefehle diktieren",
        subtitle: "Word, PowerPoint, Outlook und Proton Mail verstehen gesprochene Struktur",
        symbol: "text.alignleft")
      {
        HelpStep(number: "1", title: "Zeilen und Absätze", detail: "„Neue Zeile“ erzeugt einen einfachen Umbruch. „Neuer Absatz“ erzeugt einen Absatzabstand.")
        HelpStep(number: "2", title: "Anführungszeichen", detail: "Sage etwa „in Anführungsstrichen Projekt Apollo“ oder „Anführungszeichen auf … Anführungszeichen zu“.")
        HelpStep(number: "3", title: "Aufzählungen", detail: "Sage „Aufzählung, Punkt eins …, nächster Punkt …, Liste Ende“. Für nummerierte Punkte beginne mit „nummerierte Liste“.")
        HelpStep(number: "4", title: "Bewusst konservativ", detail: "MiddleAI formatiert nur eindeutige Befehle. Normale Aussagen wie „Die neue Zeile ist rot“ bleiben unverändert.")
        Label("Die Auswertung erfolgt lokal nach der optionalen Diktatglättung. Außerhalb der vier unterstützten Apps wird ausschließlich Klartext eingefügt.", systemImage: "lock.shield")
          .font(.caption).foregroundStyle(.secondary)
      }

      SettingsCard(
        title: "Speicherbedarf", subtitle: "Gerundete Größen der aktuellen Modellvarianten",
        symbol: "externaldrive.badge.icloud")
      {
        RequirementRow(symbol: "waveform", title: "Parakeet STT", value: "etwa 1 GB")
        RequirementRow(symbol: "speaker.wave.2", title: "Supertonic 3", value: "etwa 0,2 bis 0,4 GB")
        RequirementRow(symbol: "sparkles", title: "Qwen3-TTS", value: "etwa 2,8 GB einschließlich Laufzeit")
        RequirementRow(symbol: "waveform.badge.magnifyingglass", title: "Voxtral TTS", value: "etwa 3 GB einschließlich Laufzeit")
        Text("Voxtral steht unter CC BY-NC 4.0 und darf nicht für kommerzielle oder geschäftliche Zwecke verwendet werden.")
          .font(.caption.weight(.semibold)).foregroundStyle(.orange)
      }

      SettingsCard(
        title: "Datenschutz", subtitle: "Welche Daten den Mac verlassen",
        symbol: "lock.shield")
      {
        Label("Mikrofonaudio, STT und TTS bleiben lokal auf dem Mac.", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
        Label("Nur fertige Anfragen im MiddleAI-Modus werden an den eingestellten OpenWebUI-Server übertragen.", systemImage: "server.rack")
        Label("Diktate für aktive Textfelder werden niemals an OpenWebUI gesendet.", systemImage: "text.cursor")
      }
    }
  }

  private var routingDescription: String {
    switch state.config.routing.strategy {
    case "heuristic":
      return "Der einfache Modus berücksichtigt Zeitabstand, wiederkehrende Begriffe und typische Anschlusswörter. Er ist schnell, kann bei ähnlichen Themen aber ungenauer sein."
    default:
      return "Hybrid kombiniert Zeitabstand, Begriffe und einen lokalen Ähnlichkeitsvergleich. Das ist genauer und läuft auch ohne Ollama vollständig lokal."
    }
  }

  private var intelligenceProviderDescription: String {
    switch state.intelligenceProviderChoice {
    case "apple":
      return "Apple Intelligence läuft über das macOS-Systemmodell, benötigt keinen separaten Download in MiddleAI und bekommt nur dann Kontext, wenn Hybridregeln bei der Chat-Auswahl uneinig sind. Nicht verfügbar auf diesem Mac? Dann bleiben die eingebauten Regeln aktiv."
    case "ollama":
      return "Ollama stellt ein selbst gewähltes lokales Modell bereit. MiddleAI verwendet dessen OpenAI-kompatible API ausschließlich als Entscheidungshilfe für mehrdeutige Chat-Zuordnungen."
    case "llama_cpp":
      return "llama.cpp wird über seine lokale OpenAI-kompatible Server-API angesprochen. Für deinen Mac ist http://127.0.0.1:18881 voreingestellt. MiddleAI startet oder lädt den Server selbst nicht."
    default:
      return "MiddleAI nutzt nur Zeitabstand, Begriffe und lokale Ähnlichkeit. Das braucht weder Apple Intelligence noch einen Modellserver und ist der robusteste Rückfallmodus."
    }
  }

  private var localServerHelp: String {
    if state.intelligenceProviderChoice == "llama_cpp" {
      return "Der Server muss /v1/models und /v1/chat/completions anbieten. Bei einem llama.cpp-Router mit automatischem Laden trägst du als Modell-ID den dort konfigurierten Modellalias ein. Bleibt /v1/models leer, ist der Server zwar erreichbar, aber noch kein Modell bekannt."
    }
    return "Ollama muss laufen und das Modell muss bereits mit „ollama pull“ geladen sein. Der Standardendpunkt ist http://127.0.0.1:11434; MiddleAI ergänzt /v1 automatisch."
  }

  private var providerDescription: String {
    switch state.config.tts.provider {
    case "qwen3_tts":
      return "Qwen3-TTS VoiceDesign erzeugt eine flüssige weibliche Stimme mit neutralem Standarddeutsch und natürlicher Betonung vollständig lokal über Apple MLX. MiddleAI verwendet jetzt die stabile 4-Bit-Version mit etwa 2,3 GB."
    case "voxtral_tts":
      return "Voxtral ist Mistrals besonders natürliche lokale 4-Bit-Stimme mit etwa 2,5 GB Modelldaten. Wichtig: Die Modelllizenz CC BY-NC 4.0 erlaubt keine kommerzielle Nutzung. Für geschäftliche Inhalte ist Qwen3-TTS die sichere Auswahl."
    case "adaptive":
      return "Empfohlen: Kurze Antworten nutzt MiddleAI mit der natürlicheren lokalen Stimme. Bei längeren Texten, Zahlen und Fachbegriffen wechselt es automatisch zur zuverlässigeren deutschen Apple-Stimme."
    case "macos":
      return "Apple-Stimmen sprechen Zahlen, Satzmelodie und deutsches Fachvokabular am zuverlässigsten. Enhanced- und Premium-Stimmen werden nach dem Download automatisch bevorzugt."
    case "supertonic3":
      return "Supertonic läuft als Core-ML-Modell lokal. MiddleAI erzeugt die Antwort jetzt in einem kontinuierlichen Durchlauf und bereitet englische Produktnamen phonetisch vor."
    case "pockettts":
      return "PocketTTS bleibt als lokale Alternative verfügbar, kann bei Deutsch aber einen hörbaren Akzent haben."
    default:
      return "MiddleAI startet das angegebene lokale Programm und übergibt ausschließlich den zu sprechenden Text."
    }
  }

  private func saveConnection() {
    do {
      try state.save(password: password)
      saveMessage = "Gespeichert. Verbindung wird geprüft …"
      Task {
        await state.connectAndServe()
        saveMessage = state.status == "Connected"
          ? "Gespeichert und verbunden" : state.lastError
      }
    } catch { saveMessage = error.localizedDescription }
  }

  private func openAppleVoiceSettings() {
    guard let url = URL(
      string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent")
    else { return }
    NSWorkspace.shared.open(url)
  }

  private func openPrivacySettings() {
    guard let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    else { return }
    NSWorkspace.shared.open(url)
  }
}

private struct IntelligenceStep: View {
  let number: String
  let title: String
  let detail: String

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Text(number)
        .font(.caption.weight(.bold))
        .foregroundStyle(Color.accentColor)
        .frame(width: 25, height: 25)
        .background(Color.accentColor.opacity(0.11), in: Circle())
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.callout.weight(.medium))
        Text(detail).font(.caption).foregroundStyle(.secondary)
      }
    }
  }
}

private struct SupportedFormattingApp: View {
  let name: String
  let symbol: String

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: symbol)
        .foregroundStyle(Color.accentColor)
        .frame(width: 18)
      Text(name).font(.caption.weight(.medium))
      Spacer(minLength: 0)
      Image(systemName: "checkmark.circle.fill")
        .font(.caption)
        .foregroundStyle(.green)
    }
    .padding(.horizontal, 10).padding(.vertical, 8)
    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
  }
}

private struct SettingsCard<Content: View>: View {
  let title: String
  let subtitle: String
  let symbol: String
  @ViewBuilder let content: Content

  init(
    title: String, subtitle: String, symbol: String,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.subtitle = subtitle
    self.symbol = symbol
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 15) {
      HStack(alignment: .top, spacing: 11) {
        Image(systemName: symbol)
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(Color.accentColor)
          .frame(width: 30, height: 30)
          .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
        VStack(alignment: .leading, spacing: 2) {
          Text(title).font(.headline)
          Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
      }
      Divider()
      VStack(alignment: .leading, spacing: 13) { content }
    }
    .padding(19)
    .background(
      Color(nsColor: .controlBackgroundColor).opacity(0.72),
      in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.075), lineWidth: 0.8)
    }
    .shadow(color: .black.opacity(0.035), radius: 8, y: 3)
  }
}

private struct TTSModelStatusRow: View {
  let model: TTSModelDownloadStatus
  let selected: Bool
  let onDelete: () -> Void

  private var statusColor: Color {
    switch model.phase {
    case .installed: return .green
    case .downloading: return .accentColor
    case .failed: return .red
    case .notDownloaded: return .secondary
    }
  }

  private var statusTitle: String {
    switch model.phase {
    case .installed: return "Installiert · \(model.downloadedSize)"
    case .downloading: return "Wird geladen · \(model.downloadedSize) von ca. \(model.expectedSize)"
    case .failed: return "Download nicht abgeschlossen"
    case .notDownloaded:
      return model.downloadedBytes > 0
        ? "Teilweise geladen · \(model.downloadedSize) von ca. \(model.expectedSize)"
        : "Nicht geladen · ca. \(model.expectedSize)"
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 11) {
        Image(systemName: model.phase == .installed ? "checkmark.circle.fill" : "arrow.down.circle")
          .font(.system(size: 17, weight: .medium))
          .foregroundStyle(statusColor)
          .frame(width: 22)
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 7) {
            Text(model.title).font(.callout.weight(.semibold))
            if selected {
              Text("Ausgewählt")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.11), in: Capsule())
            }
          }
          Text(model.detail).font(.caption).foregroundStyle(.secondary)
          Text(statusTitle).font(.caption.weight(.medium)).foregroundStyle(statusColor)
        }
        Spacer(minLength: 0)
        if model.downloadedBytes > 0 && model.phase != .downloading {
          Button(action: onDelete) {
            Image(systemName: "trash")
          }
          .buttonStyle(.borderless)
          .help("Modelldaten in den Papierkorb verschieben")
          .accessibilityLabel("\(model.title) löschen")
        }
      }
      if model.phase == .downloading || (model.phase == .notDownloaded && model.downloadedBytes > 0) {
        ProgressView(value: model.progress)
          .tint(model.phase == .downloading ? Color.accentColor : .secondary)
      }
      if let error = model.errorMessage, model.phase == .failed {
        Text(error).font(.caption2).foregroundStyle(.red).lineLimit(2)
      }
    }
    .padding(12)
    .background(
      selected ? Color.accentColor.opacity(0.07) : Color.primary.opacity(0.025),
      in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 13, style: .continuous)
        .strokeBorder(selected ? Color.accentColor.opacity(0.20) : Color.primary.opacity(0.055))
    }
  }
}

private struct RequirementRow: View {
  let symbol: String
  let title: String
  let value: String

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Image(systemName: symbol).foregroundStyle(Color.accentColor).frame(width: 20)
      Text(title).font(.callout.weight(.medium)).frame(width: 126, alignment: .leading)
      Text(value).font(.callout).foregroundStyle(.secondary)
      Spacer(minLength: 0)
    }
  }
}

private struct HelpStep: View {
  let number: String
  let title: String
  let detail: String

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Text(number)
        .font(.caption.weight(.bold))
        .foregroundStyle(.white)
        .frame(width: 24, height: 24)
        .background(Color.accentColor, in: Circle())
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.callout.weight(.semibold))
        Text(detail).font(.caption).foregroundStyle(.secondary)
      }
    }
  }
}

private struct SettingsField: View {
  let title: String
  let prompt: String
  @Binding var text: String

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 18) {
      Text(title).frame(width: 112, alignment: .leading).foregroundStyle(.secondary)
      TextField(prompt, text: $text).textFieldStyle(.roundedBorder)
    }
  }
}

private struct VoiceSelectionCard: View {
  let voice: TTSVoiceDescriptor
  let selected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 12) {
        Image(systemName: voice.isFemale ? "person.wave.2" : "person.wave.2.fill")
          .foregroundStyle(selected ? Color.accentColor : .secondary)
          .frame(width: 24)
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 7) {
            Text(voice.name).font(.callout.weight(.semibold))
            if voice.isRecommended {
              Text("Empfohlen")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.10), in: Capsule())
            }
          }
          Text(voice.description).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.45))
      }
      .padding(11)
      .contentShape(Rectangle())
      .background(
        selected ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor).opacity(0.55),
        in: RoundedRectangle(cornerRadius: 12))
    }
    .buttonStyle(.plain)
  }
}

private struct ShortcutRow: View {
  let key: String
  let title: String
  let detail: String

  var body: some View {
    HStack(spacing: 14) {
      Text(key)
        .font(.system(.callout, design: .rounded).weight(.semibold))
        .frame(width: 72)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.callout.weight(.medium))
        Text(detail).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
    }
  }
}

private struct ActivationKeyPickerRow: View {
  let title: String
  let detail: String
  let selection: ActivationKeyChoice
  let onChange: (ActivationKeyChoice) -> Void

  var body: some View {
    HStack(spacing: 14) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.callout.weight(.medium))
        Text(detail).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      Picker(
        title,
        selection: Binding(get: { selection }, set: onChange)
      ) {
        ForEach(ActivationKeyChoice.allCases) { key in
          Text(key.label).tag(key)
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .frame(width: 190)
    }
  }
}
