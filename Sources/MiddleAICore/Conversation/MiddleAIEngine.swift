import Foundation

public enum InputResult: Sendable, Equatable {
  case response(String, conversationID: String)
  case local(String)
  case clarification(String)
}

@MainActor public final class MiddleAIEngine {
  public let manager: ConversationManager
  public let client: any OpenWebUIClientProtocol
  public let ttsQueue: TTSQueue
  private let pipeline: ResponsePipeline
  private let detector = CommandDetector()
  private let spokenSummarizer = SpokenResponseSummarizer()
  private var config: AppConfig
  private let logger = MiddleAILogger()
  private let profiles: ProfileStore
  public private(set) var activeProfile: String
  public init(
    manager: ConversationManager, client: any OpenWebUIClientProtocol, ttsQueue: TTSQueue,
    config: AppConfig, profiles: ProfileStore = ProfileStore()
  ) {
    self.manager = manager
    self.client = client
    self.ttsQueue = ttsQueue
    self.config = config
    self.profiles = profiles
    self.activeProfile = config.activeProfile
    self.pipeline = ResponsePipeline(queue: ttsQueue, mode: config.spokenResponseMode)
  }
  public func handle(text: String, source: String = "unknown") async throws -> InputResult {
    pipeline.interrupt()
    logger.event("input_received", metadata: ["source": source, "length": "\(text.count)"])
    if let command = detector.detect(text) {
      logger.event("command_detected")
      return try handle(command)
    }
    let routingStarted = Date()
    logger.event("router_started")
    let (selected, decision) = try await manager.select(for: text)
    logger.event(
      "router_decision",
      metadata: [
        "decision": decision.decision.rawValue,
        "confidence": String(format: "%.2f", decision.confidence),
        "latency_ms": String(Int(Date().timeIntervalSince(routingStarted) * 1000)),
      ])
    if decision.decision == .askUser {
      let prompt = "Meinst du noch das vorherige Thema oder soll ich einen neuen Chat starten?"
      ttsQueue.enqueue(prompt)
      return .clarification(prompt)
    }
    var conversation: Conversation
    if let selected {
      conversation = selected
    } else {
      conversation = try manager.create(title: Self.title(from: text), profile: activeProfile)
    }
    let storedMessages = try manager.messages(for: conversation.id)
    let messages = Self.removingUnansweredUserSuffix(from: storedMessages)
    let userMessage = Message(role: .user, content: text)
    var requestMessages = messages + [userMessage]
    if let prompt = profiles.profiles[activeProfile]?.systemPrompt, !prompt.isEmpty {
      requestMessages.insert(Message(role: .system, content: prompt), at: 0)
    }
    let remoteScope = Self.remoteScope(config.openwebui.url)
    if conversation.openWebUIChatID == nil || conversation.openWebUIBaseURL != remoteScope {
      conversation.openWebUIChatID = try await client.createChat(
        title: conversation.title, messages: requestMessages, model: model)
      conversation.openWebUIBaseURL = remoteScope
      try manager.update(conversation)
      logger.event("new_conversation_created")
    }
    guard let chatID = conversation.openWebUIChatID else {
      throw MiddleAIError.invalidResponse("Missing Open WebUI chat id")
    }
    let requestStarted = Date()
    logger.event("openwebui_request_started")
    let (tokens, tokenContinuation) = AsyncStream<String>.makeStream()
    let tokenDelivery = Task { @MainActor [weak self] in
      var first = true
      for await token in tokens {
        guard let self else { return }
        if first {
          first = false
          self.logger.event(
            "first_token_received",
            metadata: [
              "latency_ms": String(Int(Date().timeIntervalSince(requestStarted) * 1000))
            ])
        }
        self.pipeline.receive(token)
      }
    }
    let response: String
    do {
      response = try await client.send(messages: requestMessages, chatID: chatID, model: model) {
        token in
        tokenContinuation.yield(token)
      }
      tokenContinuation.finish()
      await tokenDelivery.value
    } catch {
      tokenContinuation.finish()
      tokenDelivery.cancel()
      ttsQueue.enqueue("Open WebUI ist momentan nicht erreichbar.")
      logger.error("openwebui_request_failed")
      throw error
    }
    pipeline.finish()
    try Task.checkCancellation()
    if config.spokenResponseMode == "smart_summary" {
      let spoken = await spokenSummarizer.spokenText(
        for: response, threshold: config.spokenResponseThreshold,
        maximumWords: config.spokenResponseMaximumWords)
      try Task.checkCancellation()
      if !spoken.isEmpty { ttsQueue.enqueue(spoken) }
    }
    try manager.add(userMessage, to: conversation.id)
    try manager.add(Message(role: .assistant, content: response), to: conversation.id)
    conversation.lastUsedAt = Date()
    conversation.summary = Self.summary(
      messages: messages + [Message(role: .assistant, content: response)])
    try manager.update(conversation)
    logger.event(
      "response_completed",
      metadata: [
        "latency_ms": String(Int(Date().timeIntervalSince(requestStarted) * 1000))
      ])
    return .response(response, conversationID: conversation.id)
  }
  public func interrupt() {
    pipeline.interrupt()
  }
  private var model: String {
    let profileModel = profiles.profiles[activeProfile]?.model ?? ""
    return profileModel.isEmpty ? config.openwebui.model : profileModel
  }
  private func handle(_ command: LocalCommand) throws -> InputResult {
    switch command {
    case .newConversation:
      _ = try manager.create(title: "Neue Unterhaltung", profile: activeProfile)
      return .local("Neue Unterhaltung gestartet.")
    case .previousConversation:
      let c = try manager.previous()
      return .local(c.map { "Aktiver Chat: \($0.title)" } ?? "Kein vorheriger Chat gefunden.")
    case .topic(let topic):
      let c = try manager.switchToTopic(topic)
      return .local(c.map { "Aktiver Chat: \($0.title)" } ?? "Kein passendes Thema gefunden.")
    case .stop:
      pipeline.interrupt()
      return .local("Sprachausgabe gestoppt.")
    case .disableSpeech:
      ttsQueue.setEnabled(false)
      return .local("Vorlesen ist ausgeschaltet.")
    case .enableSpeech:
      ttsQueue.setEnabled(true)
      return .local("Vorlesen ist eingeschaltet.")
    case .currentConversation:
      return .local(
        manager.currentConversation.map { "Aktiver Chat: \($0.title)" } ?? "Es ist kein Chat aktiv."
      )
    case .switchProfile(let profile):
      activeProfile = profile
      return .local("Profil \(profile) ist aktiv.")
    }
  }
  private static func title(from text: String) -> String {
    let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return String(clean.prefix(72)) + (clean.count > 72 ? "…" : "")
  }
  private static func summary(messages: [Message]) -> String {
    String(messages.suffix(6).map { $0.content }.joined(separator: " ").prefix(500))
  }

  nonisolated public static func remoteScope(_ rawURL: String) -> String {
    guard var components = URLComponents(string: rawURL) else {
      return rawURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
    }
    components.query = nil
    components.fragment = nil
    if components.path == "/" { components.path = "" }
    while components.path.hasSuffix("/") { components.path.removeLast() }
    return (components.string ?? rawURL).lowercased()
  }

  nonisolated public static func removingUnansweredUserSuffix(from messages: [Message]) -> [Message] {
    var result = messages
    while result.last?.role == .user { result.removeLast() }
    return result
  }
}

public enum MiddleAIFactory {
  @MainActor public static func make(
    config: AppConfig, credentials: any CredentialStore = CompositeCredentialStore()
  ) throws -> MiddleAIEngine {
    let directory = ConfigLoader.defaultDirectory
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = try SQLiteConversationStore(
      path: directory.appendingPathComponent("middleai.sqlite").path)
    let heuristic = HeuristicRouter(continuationTimeout: config.routing.continuationTimeoutSeconds)
    var llm: (any ConversationRoutingStrategy)?
    if config.localLLM.enabled, let url = URL(string: config.localLLM.url) {
      llm = LLMRouter(endpoint: url, model: config.localLLM.model)
    }
    let router: any ConversationRoutingStrategy =
      config.routing.strategy == "heuristic"
      ? heuristic : HybridRouter(heuristic: heuristic, llm: llm)
    let manager = ConversationManager(
      store: store, router: router, confidenceAsk: config.routing.confidenceAsk)
    guard let url = URL(string: config.openwebui.url) else {
      throw MiddleAIError.configuration("Invalid Open WebUI URL")
    }
    let auth: any AuthProvider =
      config.openwebui.authMethod == "api_key"
      ? APIKeyAuthProvider(credentials: credentials)
      : PasswordAuthProvider(username: config.openwebui.username, credentials: credentials)
    let client = OpenWebUIClient(
      baseURL: url, auth: auth, tlsVerify: config.openwebui.tlsVerify,
      caFile: config.openwebui.caFile)
    let native = MacOSTTSProvider(voice: config.tts.voice, rate: config.tts.rate)
    let provider: any TTSProvider
    switch config.tts.provider {
    case "qwen3_tts":
      provider = FallbackTTSProvider(
        primary: VoxtralTTSProvider.qwen(
          voice: config.tts.voice, rate: config.tts.rate),
        fallback: MacOSTTSProvider(voice: "", rate: config.tts.rate))
    case "voxtral_tts":
      provider = FallbackTTSProvider(
        primary: VoxtralTTSProvider(voice: config.tts.voice),
        fallback: MacOSTTSProvider(voice: "", rate: config.tts.rate))
    case "adaptive":
      provider = AdaptiveGermanTTSProvider(
        natural: Supertonic3TTSProvider(
          voice: "F1", rate: config.tts.rate,
          highQuality: config.tts.quality != "fast"),
        precise: MacOSTTSProvider(voice: config.tts.voice, rate: config.tts.rate))
    case "supertonic3":
      provider = FallbackTTSProvider(
        primary: Supertonic3TTSProvider(
          voice: config.tts.voice, rate: config.tts.rate,
          highQuality: config.tts.quality != "fast"),
        fallback: MacOSTTSProvider(voice: "", rate: config.tts.rate))
    case "pockettts":
      provider = FallbackTTSProvider(
        primary: PocketTTSProvider(
          voice: config.tts.voice, highQuality: config.tts.quality != "fast",
          temperature: config.tts.temperature),
        fallback: MacOSTTSProvider(voice: "", rate: config.tts.rate))
    case "local_model":
      provider = FallbackTTSProvider(
        primary: LocalModelTTSProvider(executable: config.tts.localCommand), fallback: native)
    default:
      provider = native
    }
    return MiddleAIEngine(
      manager: manager, client: client,
      ttsQueue: TTSQueue(provider: provider, enabled: config.tts.enabled), config: config)
  }
}
