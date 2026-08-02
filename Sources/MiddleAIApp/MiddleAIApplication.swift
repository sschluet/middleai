import AppKit
import MiddleAICore
import SwiftUI

extension Notification.Name {
  fileprivate static let middleAIReopen = Notification.Name("MiddleAIReopen")
  fileprivate static let middleAIQuickInputFocus = Notification.Name("MiddleAIQuickInputFocus")
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
  }

  func applicationShouldHandleReopen(
    _ sender: NSApplication, hasVisibleWindows flag: Bool
  ) -> Bool {
    NotificationCenter.default.post(name: .middleAIReopen, object: nil)
    return true
  }
}

@main struct MiddleAIApplication: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var state = AppState()
  var body: some Scene {
    MenuBarExtra("MiddleAI", systemImage: "waveform") {
      MenuContent(state: state)
    }
    .menuBarExtraStyle(.menu)
    Settings { SettingsView(state: state).frame(minWidth: 860, minHeight: 660) }
  }
}

@MainActor final class AppState: ObservableObject {
  @Published var config = AppConfig()
  @Published var status = "Starting"
  @Published var lastError = ""
  @Published var input = ""
  @Published var responseText = ""
  @Published var isWorking = false
  @Published var needsSetup = false
  @Published var voiceStatus = "Voice wird gestartet"
  @Published var ttsStatus = "Sprachausgabe wird gestartet"
  @Published var ttsModelStatuses: [TTSModelDownloadStatus] = TTSModelLibrary.scan(
    activeModelID: nil, confirmed: [], failures: [:])
  @Published var ttsPreparingModelID: String?
  @Published var intelligenceStatus = "Bereit. Die schnelle lokale Hybrid-Auswahl ist aktiv."
  @Published var conversations: [Conversation] = []
  let credentials = CompositeCredentialStore()
  private(set) var engine: MiddleAIEngine?
  private var server: LocalInputServer?
  private var quickWindow: NSWindow?
  private var setupWindow: NSWindow?
  private var helpWindow: NSWindow?
  private var voiceController: VoiceInputController?
  private var ttsPreviewTask: Task<Void, Never>?
  private var ttsDownloadMonitorTask: Task<Void, Never>?
  private var confirmedTTSModels = Set<String>()
  private var ttsModelFailures: [String: String] = [:]
  private var reopenObserver: NSObjectProtocol?
  init() {
    reopenObserver = NotificationCenter.default.addObserver(
      forName: .middleAIReopen, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.showPrimaryWindow() }
    }
    needsSetup = !FileManager.default.fileExists(atPath: ConfigLoader.defaultURL.path)
    do {
      config = try ConfigLoader.load()
      if config.tts.provider == "adaptive" && config.tts.voice.hasPrefix("F") {
        config.tts.voice = TTSVoiceCatalog.defaultVoice(for: "adaptive")
        try? ConfigLoader.save(config)
      }
      if config.spokenResponseMode == "full" {
        config.spokenResponseMode = "smart_summary"
        try? ConfigLoader.save(config)
      }
      let usernameMissing =
        config.openwebui.authMethod == "password"
        && config.openwebui.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      let modelMissing = config.openwebui.model.trimmingCharacters(in: .whitespacesAndNewlines)
        .isEmpty
      needsSetup = needsSetup || usernameMissing || modelMissing
      try rebuild()
      refreshConversations()
      if !needsSetup { Task { await connectAndServe() } }
    } catch {
      lastError = error.localizedDescription
      status = "Configuration error"
    }
    configureVoice()
    refreshTTSModelStatuses()
    Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 350_000_000)
      if self?.needsSetup == true { self?.showSetupWindow() }
    }
  }
  private func configureVoice() {
    voiceController = VoiceInputController(
      engineProvider: { [weak self] in self?.engine },
      configProvider: { [weak self] in self?.config ?? AppConfig() },
      onStatus: { [weak self] message in self?.voiceStatus = message },
      onStarted: { [weak self] in
        self?.responseText = ""
        self?.lastError = ""
        self?.isWorking = true
      },
      onResult: { [weak self] result in
        self?.apply(result)
        self?.isWorking = false
      },
      onError: { [weak self] message in
        self?.lastError = message
        self?.isWorking = false
      },
      onDismissed: { [weak self] in
        self?.isWorking = false
      })
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(700))
      self?.voiceController?.prepare()
      self?.prepareTTSModel()
    }
  }
  var currentTitle: String {
    engine?.manager.currentConversation?.title ?? "No active conversation"
  }
  func rebuild() throws {
    server?.stop()
    engine?.ttsQueue.stop()
    engine = try MiddleAIFactory.make(config: config, credentials: credentials)
  }
  func connectAndServe() async {
    guard let engine else { return }
    status = "Connecting"
    do {
      server?.stop()
      server = nil
      server = LocalInputServer(
        engine: engine, config: config.api, credentials: credentials
      ) { [weak self] event in
        self?.handleLocalInputEvent(event)
      }
      try server?.start()
      try await engine.client.authenticate()
      let availableModels = try await engine.client.models()
      let selectedModel = config.openwebui.model.trimmingCharacters(in: .whitespacesAndNewlines)
      guard availableModels.contains(selectedModel) else {
        throw MiddleAIError.configuration(
          "Die Modell-ID „\(selectedModel)“ ist auf \(config.openwebui.url) nicht verfügbar.")
      }
      status = "Connected"
      lastError = ""
    } catch {
      status = "Offline"
      lastError = error.localizedDescription
    }
  }
  func submit(_ text: String? = nil) {
    guard let engine else { return }
    guard !isWorking else { return }
    let value = (text ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return }
    input = ""
    responseText = ""
    lastError = ""
    isWorking = true
    Task {
      do {
        try await engine.client.authenticate()
        let result = try await engine.handle(text: value, source: "menubar")
        apply(result)
      } catch {
        lastError = error.localizedDescription
      }
      isWorking = false
      objectWillChange.send()
    }
  }
  private func handleLocalInputEvent(_ event: LocalInputEvent) {
    switch event {
    case .started:
      responseText = ""
      lastError = ""
      isWorking = true
    case .completed(let result):
      apply(result)
      isWorking = false
    case .failed(let message):
      lastError = message
      isWorking = false
    }
  }
  private func apply(_ result: InputResult) {
    switch result {
    case .response(let answer, _), .local(let answer), .clarification(let answer):
      responseText = answer
    }
    refreshConversations()
  }
  func newConversation() {
    guard let engine else { return }
    do {
      _ = try engine.manager.create(
        title: "Neue Unterhaltung", profile: engine.activeProfile)
      input = ""
      responseText = ""
      lastError = ""
      refreshConversations()
    } catch {
      lastError = error.localizedDescription
    }
  }
  func refreshConversations() {
    do { conversations = try engine?.manager.list() ?? [] }
    catch { lastError = error.localizedDescription }
  }
  func activateConversation(_ conversation: Conversation) {
    guard let engine else { return }
    do {
      try engine.manager.activate(conversation.id)
      let messages = try engine.manager.messages(for: conversation.id)
      responseText = messages.last(where: { $0.role == .assistant })?.content ?? ""
      input = ""
      lastError = ""
      objectWillChange.send()
    } catch {
      lastError = error.localizedDescription
    }
  }
  func stopSpeaking() {
    engine?.ttsQueue.stop()
    voiceStatus = "Sprachausgabe gestoppt"
  }
  func openCurrentChat() {
    guard let engine, let id = engine.manager.currentConversation?.openWebUIChatID else { return }
    NSWorkspace.shared.open(engine.client.chatURL(id: id))
  }
  func save(password: String) throws {
    try ConfigLoader.save(config)
    if !password.isEmpty { try credentials.save(password, account: "password") }
    needsSetup = false
    try rebuild()
    prepareTTSModel()
  }
  var dictationPolishingStatus: String {
    DictationPolisher.availabilityDescription
  }
  func setDictationPolishing(_ enabled: Bool) {
    config.dictation.polishWithLocalAI = enabled
    do {
      try ConfigLoader.save(config)
      voiceStatus = enabled ? "Lokale Diktat-Glättung ist aktiv" : "Diktat-Glättung ist deaktiviert"
    } catch {
      lastError = error.localizedDescription
    }
  }
  func setActivationKey(_ key: ActivationKeyChoice, for mode: VoiceMode) {
    let previousDictation = config.hotkeys.dictation
    let previousAssistant = config.hotkeys.assistant
    switch mode {
    case .dictation:
      config.hotkeys.dictation = key.rawValue
      if config.hotkeys.assistant == key.rawValue {
        config.hotkeys.assistant = previousDictation
      }
    case .assistant:
      config.hotkeys.assistant = key.rawValue
      if config.hotkeys.dictation == key.rawValue {
        config.hotkeys.dictation = previousAssistant
      }
    }
    saveActivationKeys()
  }

  func resetActivationKeys() {
    config.hotkeys = AppConfig.Hotkeys()
    saveActivationKeys()
  }

  private func saveActivationKeys() {
    do {
      try ConfigLoader.save(config)
      voiceController?.reloadActivationKeys()
      voiceStatus = "Aktivierungstasten gespeichert"
    } catch {
      lastError = error.localizedDescription
    }
  }
  var availableTTSVoices: [TTSVoiceDescriptor] {
    TTSVoiceCatalog.voices(for: config.tts.provider)
  }
  var selectedTTSVoice: TTSVoiceDescriptor? {
    availableTTSVoices.first { $0.id == config.tts.voice }
  }
  func selectTTSProvider(_ provider: String) {
    guard provider != config.tts.provider else { return }
    config.tts.provider = provider
    config.tts.voice = TTSVoiceCatalog.defaultVoice(for: provider)
    applySpeechSettings(preview: provider != "local_model")
  }
  func selectTTSVoice(_ voice: String) {
    guard voice != config.tts.voice else { return }
    config.tts.voice = voice
    applySpeechSettings(preview: true)
  }
  func applySpeechSettings(preview: Bool = false) {
    ttsPreviewTask?.cancel()
    engine?.ttsQueue.stop()
    lastError = ""
    do {
      try ConfigLoader.save(config)
      try rebuild()
      guard let selectedEngine = engine else { return }
      startTTSPreparation(using: selectedEngine, preview: preview)
      Task { [weak self] in await self?.connectAndServe() }
    } catch {
      ttsStatus = "Die Spracheinstellungen konnten nicht gespeichert werden"
      lastError = error.localizedDescription
    }
  }
  private var ttsProviderName: String {
    switch config.tts.provider {
    case "qwen3_tts": return "Qwen3-TTS Deutsch"
    case "voxtral_tts": return "Mistral Voxtral TTS"
    case "adaptive": return "Automatisches Deutsch"
    case "supertonic3": return "Supertonic 3"
    case "pockettts": return "PocketTTS"
    case "macos": return "macOS-Sprachausgabe"
    case "local_model": return "Lokales TTS-Modell"
    default: return "Sprachausgabe"
    }
  }
  private var preparationStatus: String {
    switch config.tts.provider {
    case "qwen3_tts":
      return "Qwen3-TTS wird lokal über MLX vorbereitet; der erste Download umfasst etwa 2,3 GB …"
    case "voxtral_tts":
      return "Voxtral wird lokal eingerichtet; Laufzeit und 4-Bit-Modell umfassen etwa 3 GB …"
    case "adaptive": return "Lokale deutsche Stimmen werden vorbereitet…"
    case "supertonic3": return "Supertonic 3 wird lokal vorbereitet; der erste Download kann etwas dauern…"
    case "pockettts": return "PocketTTS German wird lokal vorbereitet…"
    default: return "\(ttsProviderName) wird vorbereitet…"
    }
  }
  func prepareTTSModel() {
    guard let engine, config.tts.enabled else {
      ttsStatus = "Sprachausgabe ist deaktiviert"
      return
    }
    guard ["adaptive", "pockettts", "supertonic3", "qwen3_tts", "voxtral_tts"].contains(config.tts.provider) else {
      ttsStatus = "\(ttsProviderName) ist lokal bereit"
      return
    }
    startTTSPreparation(using: engine, preview: false)
  }

  func refreshTTSModelStatuses() {
    let activeModelID = ttsPreparingModelID
    let confirmed = confirmedTTSModels
    let failures = ttsModelFailures
    Task { [weak self] in
      let statuses = await Task.detached(priority: .utility) {
        TTSModelLibrary.scan(
          activeModelID: activeModelID, confirmed: confirmed, failures: failures)
      }.value
      guard let self else { return }
      self.ttsModelStatuses = statuses
    }
  }

  func deleteTTSModel(_ model: TTSModelDownloadStatus) {
    guard model.phase != .downloading else {
      ttsStatus = "Ein laufender Modelldownload kann nicht gelöscht werden"
      return
    }
    let paths = TTSModelLibrary.deletablePaths(for: model.id).filter {
      FileManager.default.fileExists(atPath: $0.path)
    }
    guard !paths.isEmpty else {
      ttsStatus = "Für \(model.title) wurden keine Modelldaten gefunden"
      refreshTTSModelStatuses()
      return
    }
    engine?.ttsQueue.stop()
    ttsPreviewTask?.cancel()
    confirmedTTSModels.remove(model.id)
    ttsModelFailures[model.id] = nil
    if TTSModelLibrary.modelID(for: config.tts.provider) == model.id {
      config.tts.provider = "macos"
      config.tts.voice = TTSVoiceCatalog.defaultVoice(for: "macos")
      try? ConfigLoader.save(config)
      try? rebuild()
      Task { [weak self] in await self?.connectAndServe() }
    }
    ttsStatus = "\(model.title) wird in den Papierkorb verschoben …"
    NSWorkspace.shared.recycle(paths) { [weak self] _, error in
      Task { @MainActor in
        guard let self else { return }
        if let error {
          self.ttsStatus = "\(model.title) konnte nicht gelöscht werden"
          self.lastError = error.localizedDescription
        } else {
          self.ttsStatus = "\(model.title) wurde in den Papierkorb verschoben"
        }
        self.refreshTTSModelStatuses()
      }
    }
  }

  private func startTTSPreparation(using selectedEngine: MiddleAIEngine, preview: Bool) {
    ttsPreviewTask?.cancel()
    let provider = config.tts.provider
    let modelID = TTSModelLibrary.modelID(for: provider)
    ttsStatus = preparationStatus
    if let modelID {
      ttsPreparingModelID = modelID
      ttsModelFailures[modelID] = nil
      startTTSDownloadMonitor()
    } else {
      ttsPreparingModelID = nil
      refreshTTSModelStatuses()
    }
    ttsPreviewTask = Task { [weak self] in
      do {
        try await selectedEngine.ttsQueue.prepare()
        guard !Task.isCancelled else { return }
        if let modelID, provider != "adaptive" { self?.confirmedTTSModels.insert(modelID) }
        self?.lastError = ""
        self?.ttsStatus = "\(self?.ttsProviderName ?? "Sprachausgabe") ist lokal bereit"
        self?.finishTTSPreparation(modelID: modelID)
        if preview { selectedEngine.ttsQueue.enqueue(TTSVoiceCatalog.germanSample) }
      } catch is CancellationError {
        self?.finishTTSPreparation(modelID: modelID)
      } catch {
        let detail = String(error.localizedDescription.prefix(170))
        self?.ttsStatus = "Stimme nicht bereit: \(detail)"
        self?.lastError = error.localizedDescription
        if let modelID { self?.ttsModelFailures[modelID] = detail }
        self?.finishTTSPreparation(modelID: modelID)
      }
    }
  }

  private func startTTSDownloadMonitor() {
    ttsDownloadMonitorTask?.cancel()
    refreshTTSModelStatuses()
    ttsDownloadMonitorTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(800))
        guard !Task.isCancelled else { return }
        self?.refreshTTSModelStatuses()
      }
    }
  }

  private func finishTTSPreparation(modelID: String?) {
    guard ttsPreparingModelID == modelID else { return }
    ttsPreparingModelID = nil
    ttsDownloadMonitorTask?.cancel()
    ttsDownloadMonitorTask = nil
    refreshTTSModelStatuses()
  }
  func testTTS() {
    guard let engine else { return }
    engine.ttsQueue.stop()
    engine.ttsQueue.enqueue(TTSVoiceCatalog.germanSample)
  }

  func useRecommendedRouting() {
    config.routing.strategy = "hybrid"
    config.routing.continuationTimeoutSeconds = 300
    config.localLLM.enabled = true
    config.localLLM.provider = "apple"
    saveIntelligenceSettings(message: "Empfohlen aktiv: Hybrid mit Apple Intelligence als lokaler Rückfrage")
  }

  var intelligenceProviderChoice: String {
    config.localLLM.enabled ? config.localLLM.provider : "rules"
  }

  func selectIntelligenceProvider(_ provider: String) {
    switch provider {
    case "rules":
      config.localLLM.enabled = false
    case "apple":
      config.localLLM.enabled = true
      config.localLLM.provider = "apple"
    case "ollama":
      let changed = config.localLLM.provider != "ollama"
      config.localLLM.enabled = true
      config.localLLM.provider = "ollama"
      if changed {
        config.localLLM.url = "http://127.0.0.1:11434"
        config.localLLM.model = "qwen3:4b"
      }
    case "llama_cpp":
      let changed = config.localLLM.provider != "llama_cpp"
      config.localLLM.enabled = true
      config.localLLM.provider = "llama_cpp"
      if changed {
        config.localLLM.url = "http://127.0.0.1:18881"
        config.localLLM.model = ""
      }
    default: return
    }
    intelligenceStatus = "Auswahl geändert. Mit „Einstellungen speichern“ wird sie aktiv."
  }

  func saveIntelligenceSettings(message: String = "Routing-Einstellungen gespeichert") {
    if ["ollama", "llama_cpp"].contains(config.localLLM.provider),
      config.localLLM.enabled,
      config.localLLM.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      intelligenceStatus = "Bitte zuerst die Modell-ID oder den Modellalias eintragen."
      return
    }
    do {
      try ConfigLoader.save(config)
      try rebuild()
      intelligenceStatus = message
      Task { await connectAndServe() }
    } catch {
      intelligenceStatus = "Einstellungen konnten nicht gespeichert werden"
      lastError = error.localizedDescription
    }
  }

  func testLocalRouter() {
    guard config.localLLM.enabled else {
      intelligenceStatus = "Das lokale Zusatzmodell ist ausgeschaltet und wird nicht benötigt"
      return
    }
    if config.localLLM.provider == "apple" {
      intelligenceStatus = "Apple Intelligence: \(DictationPolisher.availabilityDescription)"
      return
    }
    intelligenceStatus = "Lokaler Server wird geprüft …"
    Task {
      do {
        guard let endpoint = URL(string: config.localLLM.url) else {
          throw MiddleAIError.configuration("Der lokale Modell-Endpunkt ist ungültig.")
        }
        var request = URLRequest(url: LocalLLMEndpoint.modelsURL(from: endpoint))
        request.timeoutInterval = 4
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let code = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(code)
        else { throw MiddleAIError.network("Das lokale Modell antwortet nicht.") }
        struct ModelList: Decodable { struct Model: Decodable { let id: String }; let data: [Model] }
        let models = (try? JSONDecoder().decode(ModelList.self, from: data).data.map(\.id)) ?? []
        if config.localLLM.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          let first = models.first
        {
          config.localLLM.model = first
        }
        let name = config.localLLM.provider == "llama_cpp" ? "llama.cpp" : "Ollama"
        if models.isEmpty {
          intelligenceStatus = "\(name) ist erreichbar, meldet aber noch kein geladenes Modell. Bitte Modell-ID oder Alias eintragen."
        } else {
          intelligenceStatus = "\(name) ist erreichbar · \(models.count) Modell(e) gefunden"
        }
      } catch {
        intelligenceStatus = "Lokaler Server nicht erreichbar. Endpunkt und laufenden Dienst prüfen."
        lastError = error.localizedDescription
      }
    }
  }
  func showPrimaryWindow() {
    if needsSetup {
      showSetupWindow()
    } else {
      showQuickInput()
    }
  }
  func showQuickInput() {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    if quickWindow == nil {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 960, height: 650),
        styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
        defer: false)
      window.title = "MiddleAI"
      window.titlebarAppearsTransparent = true
      window.toolbarStyle = .unified
      window.isReleasedWhenClosed = false
      window.hidesOnDeactivate = false
      window.level = .floating
      window.collectionBehavior = [.moveToActiveSpace]
      let hostingView = NSHostingView(rootView: QuickInputView(state: self))
      hostingView.frame = NSRect(x: 0, y: 0, width: 960, height: 650)
      window.contentView = hostingView
      window.minSize = NSSize(width: 820, height: 560)
      window.contentMinSize = NSSize(width: 820, height: 560)
      window.setContentSize(NSSize(width: 960, height: 650))
      quickWindow = window
    }
    quickWindow?.center()
    quickWindow?.makeKeyAndOrderFront(nil)
    DispatchQueue.main.async {
      NotificationCenter.default.post(name: .middleAIQuickInputFocus, object: nil)
    }
  }
  func showSetupWindow() {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    if setupWindow == nil {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 880, height: 700),
        styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
        defer: false)
      window.title = stateWindowTitle
      window.titlebarAppearsTransparent = true
      window.toolbarStyle = .unified
      window.isReleasedWhenClosed = false
      window.hidesOnDeactivate = false
      window.level = .floating
      window.collectionBehavior = [.moveToActiveSpace]
      window.contentView = NSHostingView(rootView: SettingsView(state: self))
      window.minSize = NSSize(width: 820, height: 620)
      setupWindow = window
    }
    setupWindow?.center()
    setupWindow?.makeKeyAndOrderFront(nil)
  }
  func showHelpWindow() {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    if helpWindow == nil {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 880, height: 700),
        styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
        defer: false)
      window.title = "MiddleAI-Hilfe"
      window.titlebarAppearsTransparent = true
      window.toolbarStyle = .unified
      window.isReleasedWhenClosed = false
      window.hidesOnDeactivate = false
      window.collectionBehavior = [.moveToActiveSpace]
      window.contentView = NSHostingView(rootView: SettingsView(state: self, initialPane: .help))
      window.minSize = NSSize(width: 820, height: 620)
      helpWindow = window
    }
    helpWindow?.center()
    helpWindow?.makeKeyAndOrderFront(nil)
  }
  private var stateWindowTitle: String { needsSetup ? "MiddleAI einrichten" : "MiddleAI Einstellungen" }
}

private struct MenuContent: View {
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

private struct QuickInputView: View {
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
          ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
              .fill(
                LinearGradient(
                  colors: [Color.accentColor, Color.accentColor.opacity(0.55)],
                  startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "waveform.and.sparkles")
              .font(.system(size: 16, weight: .semibold))
              .foregroundStyle(.white)
          }
          .frame(width: 36, height: 36)
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
            Button { searchText = "" } label: {
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
            Button { state.openCurrentChat() } label: {
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
                Image(systemName: "waveform.and.sparkles")
                  .font(.system(size: 32, weight: .medium))
                  .foregroundStyle(Color.accentColor)
                  .frame(width: 70, height: 70)
                  .background(
                    LinearGradient(
                      colors: [Color.accentColor.opacity(0.14), Color.purple.opacity(0.07)],
                      startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 21, style: .continuous))
                Text("Womit kann ich helfen?")
                  .font(.title2.weight(.semibold))
                Text("Schreibe eine Nachricht oder nutze die rechte Optionstaste für eine Sprachanfrage.")
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
                  in: RoundedRectangle(cornerRadius: 19, style: .continuous))
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
          Button { state.submit() } label: {
            Image(systemName: "arrow.up")
              .font(.system(size: 13, weight: .bold))
              .frame(width: 26, height: 26)
          }
          .buttonStyle(.borderedProminent)
          .buttonBorderShape(.circle)
          .disabled(state.isWorking || state.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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

private struct ConversationSidebarRow: View {
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

private struct LegacySettingsView: View {
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
                    .foregroundStyle(state.config.tts.voice == voice.id ? Color.accentColor : .secondary)
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
        Text("STT und TTS laufen vollständig lokal. Nach dem einmaligen Modelldownload werden keine Sprachdaten an einen Cloud-Dienst gesendet.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }.padding().tabItem { Label("Sprache", systemImage: "speaker.wave.2") }
      Form {
        Text("MiddleAI Voice").font(.headline)
        LabeledContent("Linke Optionstaste", value: "Diktat ins aktive Textfeld")
        LabeledContent("Rechte Optionstaste", value: "Anfrage an OpenWebUI")
        Text("Kurz drücken startet oder beendet die Aufnahme. Gedrückthalten und Loslassen funktioniert ebenfalls.")
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
          { NSWorkspace.shared.open(url) }
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
      return "Qwen3-TTS VoiceDesign erzeugt eine frei gestaltete weibliche Stimme mit neutralem Standarddeutsch lokal über Apple MLX. Die 4-Bit-Version benötigt etwa 2,3 GB."
    case "voxtral_tts":
      return "Mistral Voxtral läuft lokal über MLX und bietet eine deutsche Frauenstimme. Die CC-BY-NC-4.0-Modelllizenz schließt kommerzielle Nutzung aus."
    case "supertonic3":
      return "Supertonic 3 erzeugt Deutsch mit einem mehrsprachigen Core-ML-Modell in 44,1 kHz. Der erste Download benötigt ungefähr 400 MB; danach läuft alles offline."
    case "macos":
      return "Verwendet die in macOS installierten deutschen Stimmen. Zusätzliche und höherwertige Apple-Stimmen lassen sich in den Systemeinstellungen laden."
    case "pockettts":
      return "PocketTTS bleibt aus Kompatibilitätsgründen verfügbar. Viele Stimmstile wurden nicht speziell für Deutsch aufgenommen und können deshalb einen Akzent haben."
    default:
      return "Startet ein selbst bereitgestelltes lokales TTS-Programm. MiddleAI übergibt ihm ausschließlich den zu sprechenden Text."
    }
  }
  private func openAppleVoiceSettings() {
    guard let url = URL(
      string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent")
    else { return }
    NSWorkspace.shared.open(url)
  }
}
