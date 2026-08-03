import AppKit
import MiddleAICore
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
  static let middleAIReopen = Notification.Name("MiddleAIReopen")
  static let middleAIQuickInputFocus = Notification.Name("MiddleAIQuickInputFocus")
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.applicationIconImage = MiddleAIIconProvider.image
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
  @Published var sttStatus = "Parakeet TDT v3 wird lokal verwendet"
  @Published var ttsStatus = "Sprachausgabe wird gestartet"
  @Published var ttsModelStatuses: [TTSModelDownloadStatus] = TTSModelLibrary.scan(
    activeModelID: nil, confirmed: [], failures: [:])
  @Published var ttsPreparingModelID: String?
  @Published var voxtralLicenseAccepted = UserDefaults.standard.bool(
    forKey: "tts.voxtral.cc-by-nc-4.accepted")
  @Published var intelligenceStatus = "Bereit. Die schnelle lokale Hybrid-Auswahl ist aktiv."
  @Published var conversations: [Conversation] = []
  @Published var localCacheStatus = "Lokaler Cache wird geprüft"
  @Published var diagnosticChecks: [DiagnosticCheck] = []
  @Published var diagnosticsRunning = false
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
      if config.tts.provider == "voxtral_tts" && !voxtralLicenseAccepted {
        config.tts.provider = "macos"
        config.tts.voice = TTSVoiceCatalog.defaultVoice(for: "macos")
        try? ConfigLoader.save(config)
        ttsStatus = "Voxtral wurde deaktiviert, bis die nicht-kommerzielle Lizenz bestätigt ist"
      }
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
      applyConfiguredCacheRetention()
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
    do {
      conversations = try engine?.manager.list() ?? []
      if let statistics = try engine?.manager.cacheStatistics() {
        localCacheStatus =
          "\(statistics.conversations) Unterhaltungen · \(statistics.messages) Nachrichten"
      } else {
        localCacheStatus = "Lokaler Cache ist leer"
      }
    } catch { lastError = error.localizedDescription }
  }
  func purgeLocalHistory(olderThanDays days: Int) {
    guard let engine else { return }
    do {
      let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
      try engine.manager.purgeLocalHistory(olderThan: cutoff)
      responseText = ""
      refreshConversations()
      voiceStatus = "Lokaler Cache wurde bereinigt"
    } catch {
      lastError = error.localizedDescription
    }
  }
  func savePrivacySettings() {
    do {
      try ConfigLoader.save(config)
      applyConfiguredCacheRetention()
      refreshConversations()
      voiceStatus =
        config.privacy.localCacheRetentionDays == 0
        ? "Lokaler Cache wird dauerhaft aufbewahrt"
        : "Lokale Aufbewahrung wurde gespeichert"
    } catch {
      lastError = error.localizedDescription
    }
  }
  private func applyConfiguredCacheRetention() {
    guard config.privacy.localCacheRetentionDays > 0 else { return }
    purgeLocalHistory(olderThanDays: config.privacy.localCacheRetentionDays)
  }
  func clearLocalHistory() {
    guard let engine else { return }
    do {
      try engine.manager.clearLocalHistory()
      conversations = []
      responseText = ""
      localCacheStatus = "Lokaler Cache ist leer"
      voiceStatus = "Lokaler MiddleAI-Cache wurde gelöscht"
    } catch {
      lastError = error.localizedDescription
    }
  }
  func runDiagnostics() {
    guard let engine, !diagnosticsRunning else { return }
    diagnosticsRunning = true
    Task {
      let checks = await Doctor().run(
        config: config, credentials: credentials, client: engine.client)
      diagnosticChecks = checks
      diagnosticsRunning = false
    }
  }

  func exportDiagnostics() {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "MiddleAI-Diagnose.txt"
    panel.allowedContentTypes = [.plainText]
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    let appVersion =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? "development"
    let modelLines = ttsModelStatuses.map {
      "- \($0.title): \($0.phase) · \($0.downloadedSize)"
    }.joined(separator: "\n")
    let checkLines = diagnosticChecks.map {
      "- \($0.passed ? "OK" : "FEHLER") \($0.name)"
        + ($0.detail.map { ": \(Self.redactedDiagnosticDetail($0))" } ?? "")
    }.joined(separator: "\n")
    let report = """
      MiddleAI Diagnose
      Version: \(appVersion)
      macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
      Architektur: \(ProcessInfo.processInfo.machineHardwareName)
      TTS-Provider: \(config.tts.provider)
      OpenWebUI-Authentifizierung: \(config.openwebui.authMethod)

      Prüfungen:
      \(checkLines.isEmpty ? "- Noch nicht ausgeführt" : checkLines)

      Lokale TTS-Modelle:
      \(modelLines)

      Datenschutz: Benutzername, Zugangsdaten, Prompts und Antworten sind nicht enthalten.
      """
    do {
      try report.write(to: destination, atomically: true, encoding: .utf8)
    } catch {
      lastError = error.localizedDescription
    }
  }

  private static func redactedDiagnosticDetail(_ detail: String) -> String {
    var sanitized = detail
    if let expression = try? NSRegularExpression(pattern: #"https?://[^\s]+"#) {
      sanitized = expression.stringByReplacingMatches(
        in: sanitized, range: NSRange(sanitized.startIndex..., in: sanitized),
        withTemplate: "[Server ausgeblendet]")
    }
    return String(sanitized.prefix(300))
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
  func setDictationSmartFormatting(_ enabled: Bool) {
    config.dictation.smartFormatting = enabled
    do {
      try ConfigLoader.save(config)
      voiceStatus =
        enabled
        ? "App-spezifische Diktatformatierung ist aktiv"
        : "App-spezifische Diktatformatierung ist deaktiviert"
    } catch {
      lastError = error.localizedDescription
    }
  }
  func setDictationFormattingApplication(_ bundleIdentifier: String, enabled: Bool) {
    let identifier = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !identifier.isEmpty else { return }
    config.dictation.formattingApplications.removeAll {
      $0.caseInsensitiveCompare(identifier) == .orderedSame
    }
    if enabled { config.dictation.formattingApplications.append(identifier) }
    config.dictation.formattingApplications.sort {
      $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
    }
    do {
      try ConfigLoader.save(config)
      voiceStatus =
        enabled
        ? "Formatierungsbefehle für die ausgewählte App aktiviert"
        : "Formatierungsbefehle für die ausgewählte App deaktiviert"
    } catch {
      lastError = error.localizedDescription
    }
  }
  func applySTTSettings() {
    do {
      try ConfigLoader.save(config)
      sttStatus = "Einstellungen gespeichert. Das lokale STT-Modell wird neu geladen."
      voiceController?.reloadSTTSettings()
    } catch {
      sttStatus = "STT-Einstellungen konnten nicht gespeichert werden"
      lastError = error.localizedDescription
    }
  }
  func isDictationFormattingEnabled(for bundleIdentifier: String) -> Bool {
    config.dictation.formattingApplications.contains {
      $0.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
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
    guard provider != "voxtral_tts" || voxtralLicenseAccepted else {
      ttsStatus = "Bitte bestätige zuerst die nicht-kommerzielle Voxtral-Lizenz"
      return
    }
    config.tts.provider = provider
    config.tts.voice = TTSVoiceCatalog.defaultVoice(for: provider)
    applySpeechSettings(preview: provider != "local_model")
  }
  func acceptVoxtralLicenseAndSelect() {
    voxtralLicenseAccepted = true
    UserDefaults.standard.set(true, forKey: "tts.voxtral.cc-by-nc-4.accepted")
    selectTTSProvider("voxtral_tts")
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
    case "supertonic3":
      return "Supertonic 3 wird lokal vorbereitet; der erste Download kann etwas dauern…"
    case "pockettts": return "PocketTTS German wird lokal vorbereitet…"
    default: return "\(ttsProviderName) wird vorbereitet…"
    }
  }
  func prepareTTSModel() {
    guard let engine, config.tts.enabled else {
      ttsStatus = "Sprachausgabe ist deaktiviert"
      return
    }
    guard
      ["adaptive", "pockettts", "supertonic3", "qwen3_tts", "voxtral_tts"].contains(
        config.tts.provider)
    else {
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
    let paths =
      model.phase == .updateAvailable
      ? TTSModelLibrary.deletablePaths(for: model.id).filter {
        FileManager.default.fileExists(atPath: $0.path)
      } : []
    guard !paths.isEmpty else {
      ttsStatus = "Für \(model.title) wurden keine Modelldaten gefunden"
      refreshTTSModelStatuses()
      return
    }
    engine?.ttsQueue.stop()
    ttsPreviewTask?.cancel()
    confirmedTTSModels.remove(model.id)
    ttsModelFailures[model.id] = nil
    TTSModelLibrary.clearInstallationRecord(modelID: model.id)
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

  func repairTTSModel(_ model: TTSModelDownloadStatus) {
    guard model.phase != .downloading else { return }
    if model.id == "voxtral_tts" && !voxtralLicenseAccepted {
      ttsStatus = "Bitte bestätige zuerst die nicht-kommerzielle Voxtral-Lizenz"
      return
    }
    let paths = TTSModelLibrary.deletablePaths(for: model.id).filter {
      FileManager.default.fileExists(atPath: $0.path)
    }
    engine?.ttsQueue.stop()
    ttsPreviewTask?.cancel()
    confirmedTTSModels.remove(model.id)
    ttsModelFailures[model.id] = nil
    TTSModelLibrary.clearInstallationRecord(modelID: model.id)

    guard !paths.isEmpty else {
      continueTTSModelRepair(model)
      return
    }
    ttsStatus = "\(model.title) wird für eine saubere Neuinstallation vorbereitet …"
    NSWorkspace.shared.recycle(paths) { [weak self] _, error in
      Task { @MainActor in
        if let error {
          self?.ttsStatus = "Alte Modelldaten konnten nicht entfernt werden"
          self?.lastError = error.localizedDescription
        } else {
          self?.continueTTSModelRepair(model)
        }
      }
    }
  }

  private func continueTTSModelRepair(_ model: TTSModelDownloadStatus) {
    guard let provider = TTSModelLibrary.provider(for: model.id) else { return }
    config.tts.provider = provider
    config.tts.voice = TTSVoiceCatalog.defaultVoice(for: provider)
    do {
      try ConfigLoader.save(config)
      try rebuild()
      guard let engine else { return }
      startTTSPreparation(using: engine, preview: false)
      Task { [weak self] in await self?.connectAndServe() }
    } catch {
      ttsStatus = "\(model.title) konnte nicht neu vorbereitet werden"
      lastError = error.localizedDescription
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
      // Adaptive mode deliberately treats Supertonic as optional and swallows preparation
      // failures in favor of macOS speech. It must not create a successful-install marker.
      if provider != "adaptive" { try? TTSModelLibrary.beginInstallation(modelID: modelID) }
      startTTSDownloadMonitor()
    } else {
      ttsPreparingModelID = nil
      refreshTTSModelStatuses()
    }
    ttsPreviewTask = Task { [weak self] in
      do {
        try await selectedEngine.ttsQueue.prepare()
        guard !Task.isCancelled else { return }
        if let modelID, provider != "adaptive" {
          try TTSModelLibrary.recordSuccessfulInstallation(modelID: modelID)
          self?.confirmedTTSModels.insert(modelID)
        }
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
        if let modelID {
          TTSModelLibrary.markInstallationFailed(modelID: modelID)
          self?.ttsModelFailures[modelID] = detail
        }
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
    saveIntelligenceSettings(
      message: "Empfohlen aktiv: Hybrid mit Apple Intelligence als lokaler Rückfrage")
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
        struct ModelList: Decodable {
          struct Model: Decodable { let id: String }
          let data: [Model]
        }
        let models = (try? JSONDecoder().decode(ModelList.self, from: data).data.map(\.id)) ?? []
        if config.localLLM.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          let first = models.first
        {
          config.localLLM.model = first
        }
        let name = config.localLLM.provider == "llama_cpp" ? "llama.cpp" : "Ollama"
        if models.isEmpty {
          intelligenceStatus =
            "\(name) ist erreichbar, meldet aber noch kein geladenes Modell. Bitte Modell-ID oder Alias eintragen."
        } else {
          intelligenceStatus = "\(name) ist erreichbar · \(models.count) Modell(e) gefunden"
        }
      } catch {
        intelligenceStatus =
          "Lokaler Server nicht erreichbar. Endpunkt und laufenden Dienst prüfen."
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
  private var stateWindowTitle: String {
    needsSetup ? "MiddleAI einrichten" : "MiddleAI Einstellungen"
  }
}
