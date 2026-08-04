import Foundation

public enum InputResult: Sendable, Equatable {
  case response(String, conversationID: String)
  case local(String)
  case clarification(String)
}

@MainActor public final class MiddleAIEngine {
  public let manager: ConversationManager
  public let client: any AssistantClientProtocol
  public let ttsQueue: TTSQueue
  private let pipeline: ResponsePipeline
  private let detector = CommandDetector()
  private let spokenSummarizer: SpokenResponseSummarizer
  private var config: AppConfig
  private let logger = MiddleAILogger()
  private let requestCoordinator = AssistantRequestCoordinator()
  private var activeRequest: Task<String, Error>?
  private var activeRequestID: UUID?
  private var activeChatID: String?
  public private(set) var activeProfile: String
  public init(
    manager: ConversationManager, client: any AssistantClientProtocol, ttsQueue: TTSQueue,
    config: AppConfig
  ) {
    self.manager = manager
    self.client = client
    self.ttsQueue = ttsQueue
    self.config = config
    self.activeProfile = config.activeProfile
    self.pipeline = ResponsePipeline(queue: ttsQueue, mode: config.spokenResponseMode)
    self.spokenSummarizer = SpokenResponseSummarizer(localLLM: config.localLLM)
  }
  public func handle(text: String, source: String = "unknown") async throws -> InputResult {
    if detector.detect(text) == .stop {
      interrupt()
      logger.event("command_detected")
      return try handle(.stop)
    }
    let coordinatedRequestID = UUID()
    try await requestCoordinator.acquire(coordinatedRequestID)
    do {
      let result = try await performHandle(text: text, source: source)
      requestCoordinator.release(coordinatedRequestID)
      return result
    } catch {
      requestCoordinator.release(coordinatedRequestID)
      throw error
    }
  }

  private func performHandle(text: String, source: String) async throws -> InputResult {
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
    let messages = Self.boundedContext(
      Self.removingUnansweredUserSuffix(from: storedMessages),
      maximumCharacters: config.activeContextBudgetCharacters)
    let userMessage = Message(role: .user, content: text)
    var requestMessages = messages + [userMessage]
    let profilePrompt = config.profileSystemPrompt(for: activeProfile)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if !profilePrompt.isEmpty {
      requestMessages.insert(Message(role: .system, content: profilePrompt), at: 0)
    }
    let remoteScope = Self.remoteScope(config.assistantScope)
    if conversation.openWebUIChatID == nil || conversation.openWebUIBaseURL != remoteScope {
      conversation.openWebUIChatID = try await client.createChat(
        title: conversation.title, messages: requestMessages, model: model)
      conversation.openWebUIBaseURL = remoteScope
      try manager.update(conversation)
      logger.event("new_conversation_created")
    }
    guard let chatID = conversation.openWebUIChatID else {
      throw MiddleAIError.invalidResponse("Missing provider conversation id")
    }
    let requestStarted = Date()
    logger.event("assistant_request_started", metadata: ["provider": config.assistant.provider])
    let providerRequestID = UUID()
    activeRequestID = providerRequestID
    activeChatID = chatID
    let (tokens, tokenContinuation) = AsyncStream<String>.makeStream()
    let tokenDelivery = Task { @MainActor [weak self] () -> String in
      var first = true
      var streamedResponse = ""
      for await token in tokens {
        guard let self else { return streamedResponse }
        guard self.activeRequestID == providerRequestID else { return streamedResponse }
        streamedResponse += token
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
      return streamedResponse
    }
    let response: String
    let client = client
    let requestTask = Task {
      try await client.send(messages: requestMessages, chatID: chatID, model: model) { token in
        tokenContinuation.yield(token)
      }
    }
    activeRequest = requestTask
    activeRequestID = providerRequestID
    defer {
      if activeRequestID == providerRequestID {
        activeRequest = nil
        activeRequestID = nil
        activeChatID = nil
      }
    }
    do {
      response = try await withTaskCancellationHandler {
        try await requestTask.value
      } onCancel: {
        requestTask.cancel()
      }
      tokenContinuation.finish()
      let streamedResponse = await tokenDelivery.value
      if streamedResponse != response {
        // A provider may rewrite a research preamble or an outlet filter may replace the draft.
        // Reset buffered/spoken draft state so the canonical final answer wins deterministically.
        pipeline.interrupt()
        pipeline.receive(response)
      }
    } catch {
      tokenContinuation.finish()
      tokenDelivery.cancel()
      if requestTask.isCancelled || Task.isCancelled
        || (error as? URLError)?.code == .cancelled
      {
        if activeRequestID == providerRequestID { pipeline.interrupt() }
        logger.event("assistant_request_cancelled")
        throw CancellationError()
      }
      if activeRequestID == providerRequestID { pipeline.interrupt() }
      ttsQueue.enqueue("Der ausgewählte KI-Anbieter ist momentan nicht erreichbar.")
      logger.error("assistant_request_failed_\(config.assistant.provider)")
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
    let assistantMessage = Message(role: .assistant, content: response)
    conversation.lastUsedAt = Date()
    conversation.summary = Self.summary(
      messages: messages + [userMessage, assistantMessage])
    try manager.saveExchange(
      user: userMessage, assistant: assistantMessage, conversation: conversation)
    logger.event(
      "response_completed",
      metadata: [
        "latency_ms": String(Int(Date().timeIntervalSince(requestStarted) * 1000))
      ])
    return .response(response, conversationID: conversation.id)
  }
  public func interrupt() {
    cancelActiveRequest()
    pipeline.interrupt()
  }
  private func cancelActiveRequest() {
    activeRequest?.cancel()
    activeRequest = nil
    activeRequestID = nil
    if let chatID = activeChatID {
      let client = client
      Task { await client.cancel(chatID: chatID) }
    }
    activeChatID = nil
  }
  private var model: String { config.assistantModel }

  public func activateProfile(_ profile: String) {
    guard AppConfig.supportedProfileIDs.contains(profile) else { return }
    activeProfile = profile
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

  nonisolated public static func removingUnansweredUserSuffix(from messages: [Message]) -> [Message]
  {
    var result = messages
    while result.last?.role == .user { result.removeLast() }
    return result
  }

  nonisolated public static func boundedContext(
    _ messages: [Message], maximumCharacters: Int
  ) -> [Message] {
    let limit = max(1, maximumCharacters)
    var selected: [Message] = []
    var remaining = limit
    for message in messages.reversed() {
      if message.content.count <= remaining {
        selected.append(message)
        remaining -= message.content.count
      } else if selected.isEmpty {
        var truncated = message
        truncated.content = "…" + String(message.content.suffix(max(0, remaining - 1)))
        selected.append(truncated)
        remaining = 0
      } else {
        break
      }
      if remaining == 0 { break }
    }
    return selected.reversed()
  }
}

public enum MiddleAIFactory {
  @MainActor public static func make(
    config sourceConfig: AppConfig, credentials: any CredentialStore = CompositeCredentialStore(),
    conversationStore: (any ConversationStoreProtocol)? = nil
  ) throws -> MiddleAIEngine {
    let config = sourceConfig.resolved()
    let directory = ConfigLoader.defaultDirectory
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store: any ConversationStoreProtocol
    if let conversationStore {
      store = conversationStore
    } else {
      store = try SQLiteConversationStore(
        path: directory.appendingPathComponent("middleai.sqlite").path)
    }
    let heuristic = HeuristicRouter(continuationTimeout: config.routing.continuationTimeoutSeconds)
    var llm: (any ConversationRoutingStrategy)?
    if config.localLLM.enabled {
      if config.localLLM.provider == "apple" {
        llm = AppleIntelligenceRouter()
      } else if let url = URL(string: config.localLLM.url) {
        llm = LLMRouter(
          endpoint: url, model: config.localLLM.model, timeout: config.localLLM.timeoutSeconds,
          circuitBreakerFailures: config.localLLM.circuitBreakerFailures,
          circuitBreakerCooldown: config.localLLM.circuitBreakerCooldownSeconds)
      }
    }
    let router: any ConversationRoutingStrategy =
      config.routing.strategy == "heuristic"
      ? heuristic
      : HybridRouter(
        heuristic: heuristic, llm: llm,
        confidenceContinue: config.routing.confidenceContinue)
    let manager = ConversationManager(
      store: store, router: router, confidenceAsk: config.routing.confidenceAsk)
    let client = try makeAssistantClient(config: config, credentials: credentials)
    TTSOutputDevicePreference.uid = config.tts.outputDeviceUID
    let ttsOptions = TTSLocalOptions(
      pronunciations: config.tts.pronunciationDictionary,
      cacheMaximumBytes: config.tts.cacheEnabled
        ? Int64(config.tts.cacheMaximumMegabytes) * 1_048_576 : 0)
    let native = MacOSTTSProvider(
      voice: config.tts.voice, rate: config.tts.rate, options: ttsOptions)
    let provider: any TTSProvider
    switch config.tts.provider {
    case "qwen3_tts":
      provider = FallbackTTSProvider(
        primary: VoxtralTTSProvider.qwen(
          voice: config.tts.voice, rate: config.tts.rate, options: ttsOptions),
        fallback: MacOSTTSProvider(voice: "", rate: config.tts.rate, options: ttsOptions))
    case "voxtral_tts":
      provider = FallbackTTSProvider(
        primary: VoxtralTTSProvider(voice: config.tts.voice, options: ttsOptions),
        fallback: MacOSTTSProvider(voice: "", rate: config.tts.rate, options: ttsOptions))
    case "adaptive":
      provider = AdaptiveGermanTTSProvider(
        natural: Supertonic3TTSProvider(
          voice: "F1", rate: config.tts.rate,
          highQuality: config.tts.quality != "fast", options: ttsOptions),
        precise: MacOSTTSProvider(
          voice: config.tts.voice, rate: config.tts.rate, options: ttsOptions))
    case "supertonic3":
      provider = FallbackTTSProvider(
        primary: Supertonic3TTSProvider(
          voice: config.tts.voice, rate: config.tts.rate,
          highQuality: config.tts.quality != "fast", options: ttsOptions),
        fallback: MacOSTTSProvider(voice: "", rate: config.tts.rate, options: ttsOptions))
    case "pockettts":
      provider = FallbackTTSProvider(
        primary: PocketTTSProvider(
          voice: config.tts.voice, highQuality: config.tts.quality != "fast",
          temperature: config.tts.temperature, options: ttsOptions),
        fallback: MacOSTTSProvider(voice: "", rate: config.tts.rate, options: ttsOptions))
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

  public static func makeAssistantClient(
    config: AppConfig, credentials: any CredentialStore
  ) throws -> any AssistantClientProtocol {
    switch config.assistant.provider {
    case "openai":
      return HostedAIClient(
        provider: .openai, credentials: credentials,
        contextTokenBudget: config.openai.contextTokenBudget)
    case "openrouter":
      return HostedAIClient(
        provider: .openrouter, credentials: credentials,
        contextTokenBudget: config.openrouter.contextTokenBudget)
    default:
      guard let url = URL(string: config.openwebui.url) else {
        throw MiddleAIError.configuration("Invalid Open WebUI URL")
      }
      let scopedCredentials = ScopedCredentialStore(
        base: credentials, baseURL: config.openwebui.url, profile: config.activeProfile)
      let auth: any AuthProvider =
        config.openwebui.authMethod == "api_key"
        ? APIKeyAuthProvider(credentials: scopedCredentials)
        : PasswordAuthProvider(username: config.openwebui.username, credentials: scopedCredentials)
      return OpenWebUIClient(
        baseURL: url, auth: auth, tlsVerify: config.openwebui.tlsVerify,
        caFile: config.openwebui.caFile)
    }
  }
}
