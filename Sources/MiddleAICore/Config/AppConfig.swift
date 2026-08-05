import Foundation

public struct AppConfig: Codable, Equatable, Sendable {
  public struct Assistant: Codable, Equatable, Sendable {
    /// `openwebui`, `openai`, or `openrouter`.
    public var provider = "openwebui"
  }
  public struct HostedAI: Codable, Equatable, Sendable {
    public var model = ""
    public var contextTokenBudget = HostedContextWindow.defaultTokenBudget
  }
  public struct OpenWebUI: Codable, Equatable, Sendable {
    public var url = "http://127.0.0.1:3000"
    public var authMethod = "password"
    public var username = ""
    public var model = ""
    public var tlsVerify = true
    public var caFile: String?
  }
  public struct Routing: Codable, Equatable, Sendable {
    public var strategy = "hybrid"
    public var continuationTimeoutSeconds: TimeInterval = 300
    public var confidenceContinue = 0.80
    public var confidenceAsk = 0.55
  }
  public struct LocalLLM: Codable, Equatable, Sendable {
    public var enabled = false
    public var provider = "ollama"
    public var url = "http://127.0.0.1:11434"
    public var model = "qwen3:4b"
    public var timeoutSeconds: TimeInterval = 4
    public var circuitBreakerFailures = 3
    public var circuitBreakerCooldownSeconds: TimeInterval = 30
  }
  public struct TTS: Codable, Equatable, Sendable {
    public var enabled = true
    public var provider = "adaptive"
    public var fallbackProvider = "macos"
    public var localOnly = true
    public var voice = "F1"
    public var rate: Float = 1.0
    public var quality = "high"
    public var temperature: Float = 0.65
    public var localCommand = ""
    /// Core Audio device UID, or `system_default` to follow the macOS output selection.
    public var outputDeviceUID = "system_default"
    /// User-maintained word-to-pronunciation replacements applied locally before synthesis.
    public var pronunciationDictionary: [String: String] = [:]
    /// Reuses locally rendered model audio without retaining spoken source text in filenames.
    public var cacheEnabled = true
    public var cacheMaximumMegabytes = 256
  }
  public struct STT: Codable, Equatable, Sendable {
    /// Parakeet TDT v3 is the multilingual model supported by MiddleAI.
    public var model = "parakeet_tdt_v3"
    /// `de` enables the Latin-script safety filter; `auto` leaves multilingual decoding open.
    public var language = "de"
    /// The encoder can be downloaded in int8 or the smaller int4 representation.
    public var encoderPrecision = "int8"
    /// `efficient` favors the Neural Engine; `fast` uses the GPU for the encoder.
    public var computeMode = "efficient"
    /// Improves multilingual recordings longer than roughly 30 seconds at extra compute cost.
    public var longFormMode = "accurate"
    /// Core Audio device UID, or `system_default` to follow the macOS input selection.
    public var inputDeviceUID = "system_default"
    /// Hard RAM and interaction bound for one recording.
    public var maximumRecordingSeconds = 120
    /// Optional energy-based stop after speech followed by sustained silence.
    public var automaticSilenceStop = false
  }
  public struct Dictation: Codable, Equatable, Sendable {
    public static let defaultFormattingApplications = [
      "com.microsoft.Word",
      "com.microsoft.Powerpoint",
      "com.microsoft.Outlook",
      "ch.protonmail.desktop",
    ]

    public var polishWithLocalAI = true
    public var smartFormatting = true
    public var formattingApplications = Self.defaultFormattingApplications
  }
  public struct Hotkeys: Codable, Equatable, Sendable {
    public var dictation: String
    public var assistant: String
    public var dictationDoubleTap: Bool
    public var assistantDoubleTap: Bool

    public init(
      dictation: String = "left_option", assistant: String = "right_option",
      dictationDoubleTap: Bool = true, assistantDoubleTap: Bool = true
    ) {
      self.dictation = dictation
      self.assistant = assistant
      self.dictationDoubleTap = dictationDoubleTap
      self.assistantDoubleTap = assistantDoubleTap
    }
  }
  public struct API: Codable, Equatable, Sendable {
    public var bind = "127.0.0.1"
    public var port: UInt16 = 8765
    /// Existing configurations retain their explicit value. New installations start securely.
    public var tokenRequired = true
    public var requestTimeoutSeconds: TimeInterval = 15
    public var maximumBodyBytes = 1_048_576
    public var maximumQueueDepth = 16
    public var maximumConcurrentRequests = 2
  }
  public struct Logging: Codable, Equatable, Sendable {
    /// Reserved for configuration compatibility. Runtime logging currently uses a fixed,
    /// privacy-safe OSLog level rather than accepting dynamic verbosity.
    public var level = "INFO"
    /// Reserved and deliberately ignored. MiddleAI never writes prompts or responses to logs.
    public var logPrompts = false
  }
  public struct Privacy: Codable, Equatable, Sendable {
    /// Number of days to retain MiddleAI's local routing copy. Zero keeps it indefinitely.
    public var localCacheRetentionDays = 90
  }
  public struct Profiles: Codable, Equatable, Sendable {
    public var systemPrompts: [String: String] = AppConfig.defaultProfileSystemPrompts
    public var overrides: [String: ProfileOverrides] = [:]
  }
  public struct ProfileOverrides: Codable, Equatable, Sendable {
    /// Uses the globally selected answer provider when nil.
    public var assistantProvider: String?
    /// Uses the provider's globally selected model when nil.
    public var model: String?
    /// Uses the globally selected TTS voice when nil.
    public var ttsVoice: String?
    /// `smart_summary`, `full`, or `first_paragraph`; nil inherits the global mode.
    public var spokenResponseMode: String?
    /// Approximate local conversation context budget. Nil uses the global default of 48,000.
    public var contextBudgetCharacters: Int?

    public init(
      assistantProvider: String? = nil, model: String? = nil, ttsVoice: String? = nil,
      spokenResponseMode: String? = nil, contextBudgetCharacters: Int? = nil
    ) {
      self.assistantProvider = assistantProvider
      self.model = model
      self.ttsVoice = ttsVoice
      self.spokenResponseMode = spokenResponseMode
      self.contextBudgetCharacters = contextBudgetCharacters
    }
  }

  public static let supportedProfileIDs = [
    "default", "management", "architecture", "coding", "research",
  ]
  public static let defaultProfileSystemPrompts: [String: String] = [
    "default": "",
    "management":
      "Du bist ein erfahrener Management-Sparringspartner. Strukturiere Entscheidungen klar, benenne Chancen und Risiken und formuliere umsetzbare nächste Schritte.",
    "architecture":
      "Du bist ein Enterprise-IT-Architekt. Antworte technisch präzise, berücksichtige Abhängigkeiten, Sicherheit, Betrieb und langfristige Wartbarkeit.",
    "coding":
      "Du bist ein erfahrener Softwareentwickler. Liefere robuste, verständliche und wartbare Lösungen, erkläre wichtige Entscheidungen und weise auf relevante Tests hin.",
    "research":
      "Du arbeitest als sorgfältiger Recherche-Assistent. Trenne belegte Fakten von Schlussfolgerungen, berücksichtige Aktualität und Unsicherheiten und fasse die wichtigsten Ergebnisse strukturiert zusammen.",
  ]
  public var assistant = Assistant()
  public var openwebui = OpenWebUI()
  public var openai = HostedAI()
  public var openrouter = HostedAI()
  public var routing = Routing()
  public var localLLM = LocalLLM()
  public var tts = TTS()
  public var stt = STT()
  public var dictation = Dictation()
  public var hotkeys = Hotkeys()
  public var api = API()
  public var logging = Logging()
  public var privacy = Privacy()
  public var profiles = Profiles()
  public var spokenResponseMode = "smart_summary"
  public var spokenResponseThreshold = 850
  public var spokenResponseMaximumWords = 110
  public var activeProfile = "default"

  public init() {}

  public func profileSystemPrompt(for profile: String) -> String {
    profiles.systemPrompts[profile] ?? ""
  }

  public func profileOverrides(for profile: String) -> ProfileOverrides {
    profiles.overrides[profile] ?? ProfileOverrides()
  }

  public func resolved(for profile: String? = nil) -> AppConfig {
    let profile = profile ?? activeProfile
    var resolved = self
    resolved.activeProfile = profile
    let overrides = profileOverrides(for: profile)
    if let provider = overrides.assistantProvider, !provider.isEmpty {
      resolved.assistant.provider = provider
    }
    if let model = overrides.model, !model.isEmpty { resolved.assistantModel = model }
    if let voice = overrides.ttsVoice, !voice.isEmpty { resolved.tts.voice = voice }
    if let mode = overrides.spokenResponseMode, !mode.isEmpty {
      resolved.spokenResponseMode = mode
    }
    return resolved
  }

  public var activeContextBudgetCharacters: Int {
    profileOverrides(for: activeProfile).contextBudgetCharacters ?? 48_000
  }

  public static func defaultProfileSystemPrompt(for profile: String) -> String {
    defaultProfileSystemPrompts[profile] ?? ""
  }

  public var assistantModel: String {
    get {
      switch assistant.provider {
      case "openai": return openai.model
      case "openrouter": return openrouter.model
      default: return openwebui.model
      }
    }
    set {
      switch assistant.provider {
      case "openai": openai.model = newValue
      case "openrouter": openrouter.model = newValue
      default: openwebui.model = newValue
      }
    }
  }

  public var assistantProviderTitle: String {
    switch assistant.provider {
    case "openai": return "OpenAI"
    case "openrouter": return "OpenRouter"
    default: return "OpenWebUI"
    }
  }

  public var assistantScope: String {
    switch assistant.provider {
    case "openai": return "openai://platform"
    case "openrouter": return "openrouter://platform"
    default: return openwebui.url
    }
  }
}

extension String {
  fileprivate var middleAIIsLoopback: Bool {
    ["localhost", "127.0.0.1", "::1"].contains(lowercased())
  }
}

public enum ConfigLoader {
  public static let currentSchemaVersion = 1

  public static var defaultDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".middleai")
  }
  public static var defaultURL: URL { defaultDirectory.appendingPathComponent("config.yaml") }

  /// Loads the canonical JSON representation (JSON is valid YAML 1.2) or migrates the legacy
  /// hand-written YAML format. A successful legacy load is backed up and atomically rewritten.
  public static func load(from url: URL = defaultURL) throws -> AppConfig {
    guard FileManager.default.fileExists(atPath: url.path) else { return AppConfig() }
    let text = try String(contentsOf: url, encoding: .utf8)
    let config = try parseYAML(text)
    let isLegacy = text.trimmingCharacters(in: .whitespacesAndNewlines).first != "{"
    if isLegacy {
      let backup = url.appendingPathExtension("legacy-backup")
      if !FileManager.default.fileExists(atPath: backup.path) {
        try Data(text.utf8).write(to: backup, options: .atomic)
        try secureExistingPath(backup, permissions: 0o600)
      }
      try save(config, to: url)
    }
    if url.deletingLastPathComponent().standardizedFileURL == defaultDirectory.standardizedFileURL {
      try secureExistingPath(url.deletingLastPathComponent(), permissions: 0o700)
    }
    try secureExistingPath(url, permissions: 0o600)
    return config
  }

  public static func save(_ config: AppConfig, to url: URL = defaultURL) throws {
    try validate(config)
    let directory = url.deletingLastPathComponent()
    let directoryExisted = FileManager.default.fileExists(atPath: directory.path)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
    if !directoryExisted || directory.standardizedFileURL == defaultDirectory.standardizedFileURL {
      try secureExistingPath(directory, permissions: 0o700)
    }
    let data = Data(renderYAML(config).utf8)
    try data.write(to: url, options: .atomic)
    try secureExistingPath(url, permissions: 0o600)
  }

  public static func parseYAML(_ text: String) throws -> AppConfig {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let config: AppConfig
    if trimmed.first == "{" {
      config = try parseCanonical(Data(trimmed.utf8))
    } else {
      config = try parseLegacyYAML(text)
    }
    try validate(config)
    return config
  }

  /// Canonical configuration. JSON is deliberately used because it is a strict subset of YAML
  /// 1.2 and gives us escaping, arrays and forward-compatible Codable semantics without another
  /// parser dependency.
  public static func renderYAML(_ config: AppConfig) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let encoded =
      (try? encoder.encode(config)).flatMap {
        try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
      } ?? [:]
    let envelope: [String: Any] = [
      "schema_version": currentSchemaVersion,
      "config": encoded,
    ]
    let data =
      (try? JSONSerialization.data(
        withJSONObject: envelope, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
      ?? Data("{}".utf8)
    return String(decoding: data, as: UTF8.self) + "\n"
  }

  private static func parseCanonical(_ data: Data) throws -> AppConfig {
    guard
      let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let schema = root["schema_version"] as? Int,
      let values = root["config"] as? [String: Any]
    else {
      throw MiddleAIError.configuration("Configuration envelope is invalid")
    }
    guard schema > 0, schema <= currentSchemaVersion else {
      throw MiddleAIError.configuration(
        "Unsupported configuration schema version \(schema)")
    }
    let defaultsData = try JSONEncoder().encode(AppConfig())
    let defaults = try JSONSerialization.jsonObject(with: defaultsData) as? [String: Any] ?? [:]
    let merged = deepMerge(defaults: defaults, values: values)
    let mergedData = try JSONSerialization.data(withJSONObject: merged)
    do {
      return try JSONDecoder().decode(AppConfig.self, from: mergedData)
    } catch {
      throw MiddleAIError.configuration(
        "Configuration values are invalid: \(error.localizedDescription)")
    }
  }

  private static func deepMerge(defaults: [String: Any], values: [String: Any]) -> [String: Any] {
    var result = defaults
    for (key, value) in values {
      if let nestedDefaults = defaults[key] as? [String: Any],
        let nestedValues = value as? [String: Any]
      {
        result[key] = deepMerge(defaults: nestedDefaults, values: nestedValues)
      } else {
        result[key] = value
      }
    }
    return result
  }

  private static func parseLegacyYAML(_ text: String) throws -> AppConfig {
    var c = AppConfig()
    // Legacy installations explicitly defaulted to unauthenticated local HTTP access.
    c.api.tokenRequired = false
    var section = ""
    for (index, raw) in text.components(separatedBy: .newlines).enumerated() {
      let noComment = removingComment(from: raw)
      if noComment.trimmingCharacters(in: .whitespaces).isEmpty { continue }
      let indent = noComment.prefix { $0 == " " }.count
      let parts = noComment.trimmingCharacters(in: .whitespaces).split(
        separator: ":", maxSplits: 1, omittingEmptySubsequences: false
      ).map(String.init)
      if indent == 0, parts.count == 2, parts[1].isEmpty {
        section = snake(parts[0])
        continue
      }
      guard parts.count == 2 else {
        throw MiddleAIError.configuration("Invalid configuration at line \(index + 1)")
      }
      let key = snake(parts[0])
      let value = try unquote(parts[1].trimmingCharacters(in: .whitespaces))
      switch (section, key) {
      case ("assistant", "provider"): c.assistant.provider = value
      case ("openwebui", "url"): c.openwebui.url = value
      case ("openwebui", "auth_method"): c.openwebui.authMethod = value
      case ("openwebui", "username"): c.openwebui.username = value
      case ("openwebui", "model"): c.openwebui.model = value
      case ("openwebui", "tls_verify"): c.openwebui.tlsVerify = try legacyBool(value, line: index)
      case ("openwebui", "ca_file"): c.openwebui.caFile = value.isEmpty ? nil : value
      case ("routing", "strategy"): c.routing.strategy = value
      case ("routing", "continuation_timeout_seconds"):
        c.routing.continuationTimeoutSeconds = try legacyDouble(value, line: index)
      case ("routing", "confidence_continue"):
        c.routing.confidenceContinue = try legacyDouble(value, line: index)
      case ("routing", "confidence_ask"):
        c.routing.confidenceAsk = try legacyDouble(value, line: index)
      case ("local_llm", "enabled"): c.localLLM.enabled = try legacyBool(value, line: index)
      case ("local_llm", "provider"): c.localLLM.provider = value
      case ("local_llm", "url"): c.localLLM.url = value
      case ("local_llm", "model"): c.localLLM.model = value
      case ("local_llm", "timeout_seconds"):
        c.localLLM.timeoutSeconds = try legacyDouble(value, line: index)
      case ("local_llm", "circuit_breaker_failures"):
        c.localLLM.circuitBreakerFailures = try legacyInt(value, line: index)
      case ("local_llm", "circuit_breaker_cooldown_seconds"):
        c.localLLM.circuitBreakerCooldownSeconds = try legacyDouble(value, line: index)
      case ("tts", "enabled"): c.tts.enabled = try legacyBool(value, line: index)
      case ("tts", "provider"): c.tts.provider = value
      case ("tts", "fallback_provider"): c.tts.fallbackProvider = value
      case ("tts", "local_only"): c.tts.localOnly = try legacyBool(value, line: index)
      case ("tts", "voice"): c.tts.voice = value
      case ("tts", "rate"): c.tts.rate = Float(try legacyDouble(value, line: index))
      case ("tts", "quality"): c.tts.quality = value
      case ("tts", "temperature"):
        c.tts.temperature = Float(try legacyDouble(value, line: index))
      case ("tts", "local_command"): c.tts.localCommand = value
      case ("tts", "output_device_uid"): c.tts.outputDeviceUID = value
      case ("tts", "cache_enabled"): c.tts.cacheEnabled = try legacyBool(value, line: index)
      case ("tts", "cache_maximum_megabytes"):
        c.tts.cacheMaximumMegabytes = try legacyInt(value, line: index)
      case ("openai", "model"): c.openai.model = value
      case ("openai", "context_token_budget"):
        c.openai.contextTokenBudget = try legacyInt(value, line: index)
      case ("openrouter", "model"): c.openrouter.model = value
      case ("openrouter", "context_token_budget"):
        c.openrouter.contextTokenBudget = try legacyInt(value, line: index)
      case ("stt", "model"): c.stt.model = value
      case ("stt", "language"): c.stt.language = value
      case ("stt", "encoder_precision"): c.stt.encoderPrecision = value
      case ("stt", "compute_mode"): c.stt.computeMode = value
      case ("stt", "long_form_mode"): c.stt.longFormMode = value
      case ("stt", "input_device_uid"): c.stt.inputDeviceUID = value
      case ("stt", "maximum_recording_seconds"):
        c.stt.maximumRecordingSeconds = try legacyInt(value, line: index)
      case ("stt", "automatic_silence_stop"):
        c.stt.automaticSilenceStop = try legacyBool(value, line: index)
      case ("dictation", "polish_with_local_ai"):
        c.dictation.polishWithLocalAI = try legacyBool(value, line: index)
      case ("dictation", "smart_formatting"):
        c.dictation.smartFormatting = try legacyBool(value, line: index)
      case ("dictation", "formatting_applications"):
        c.dictation.formattingApplications = value.split(separator: ",")
          .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
          .filter { !$0.isEmpty }
      case ("hotkeys", "dictation"): c.hotkeys.dictation = value
      case ("hotkeys", "assistant"): c.hotkeys.assistant = value
      case ("hotkeys", "dictation_double_tap"):
        c.hotkeys.dictationDoubleTap = try legacyBool(value, line: index)
      case ("hotkeys", "assistant_double_tap"):
        c.hotkeys.assistantDoubleTap = try legacyBool(value, line: index)
      case ("api", "bind"): c.api.bind = value
      case ("api", "port"):
        guard let port = UInt16(value) else {
          throw MiddleAIError.configuration("Invalid number at line \(index + 1)")
        }
        c.api.port = port
      case ("api", "token_required"): c.api.tokenRequired = try legacyBool(value, line: index)
      case ("api", "request_timeout_seconds"):
        c.api.requestTimeoutSeconds = try legacyDouble(value, line: index)
      case ("api", "maximum_body_bytes"):
        c.api.maximumBodyBytes = try legacyInt(value, line: index)
      case ("api", "maximum_queue_depth"):
        c.api.maximumQueueDepth = try legacyInt(value, line: index)
      case ("api", "maximum_concurrent_requests"):
        c.api.maximumConcurrentRequests = try legacyInt(value, line: index)
      case ("logging", "level"): c.logging.level = value
      case ("logging", "log_prompts"): c.logging.logPrompts = try legacyBool(value, line: index)
      case ("privacy", "local_cache_retention_days"):
        c.privacy.localCacheRetentionDays = try legacyInt(value, line: index)
      case ("spoken_response", "mode"): c.spokenResponseMode = value
      case ("spoken_response", "threshold"):
        c.spokenResponseThreshold = try legacyInt(value, line: index)
      case ("spoken_response", "maximum_words"):
        c.spokenResponseMaximumWords = try legacyInt(value, line: index)
      case ("profile", "active"): c.activeProfile = value
      default: continue
      }
    }
    return c
  }

  private static func validate(_ c: AppConfig) throws {
    let assistantProviders = ["openwebui", "openai", "openrouter"]
    guard assistantProviders.contains(c.assistant.provider) else {
      throw MiddleAIError.configuration("assistant.provider is invalid")
    }
    guard let webURL = URL(string: c.openwebui.url), ["http", "https"].contains(webURL.scheme),
      webURL.user == nil, webURL.password == nil
    else {
      throw MiddleAIError.configuration("openwebui.url must be an HTTP or HTTPS URL")
    }
    guard ["password", "api_key"].contains(c.openwebui.authMethod),
      c.openwebui.username.count <= 320, c.openwebui.model.count <= 512,
      c.openai.model.count <= 512, c.openrouter.model.count <= 512,
      (512...1_000_000).contains(c.openai.contextTokenBudget),
      (512...1_000_000).contains(c.openrouter.contextTokenBudget),
      (c.openwebui.caFile?.count ?? 0) <= 4_096
    else {
      throw MiddleAIError.configuration("Answer provider settings are invalid")
    }
    guard c.api.bind == "127.0.0.1" || c.api.bind == "::1" else {
      throw MiddleAIError.configuration("api.bind must be loopback")
    }
    guard c.api.port > 0 else { throw MiddleAIError.configuration("api.port must not be zero") }
    guard (1...120).contains(c.api.requestTimeoutSeconds) else {
      throw MiddleAIError.configuration("api.request_timeout_seconds must be between 1 and 120")
    }
    guard (1_024...8_388_608).contains(c.api.maximumBodyBytes) else {
      throw MiddleAIError.configuration("api.maximum_body_bytes is outside the safe range")
    }
    guard (1...100).contains(c.api.maximumQueueDepth),
      (1...8).contains(c.api.maximumConcurrentRequests)
    else {
      throw MiddleAIError.configuration("API concurrency limits are invalid")
    }
    guard c.tts.localOnly else {
      throw MiddleAIError.configuration("MiddleAI requires tts.local_only=true")
    }
    guard (0...1).contains(c.routing.confidenceAsk),
      (0...1).contains(c.routing.confidenceContinue),
      c.routing.continuationTimeoutSeconds.isFinite,
      c.routing.continuationTimeoutSeconds > 0,
      c.routing.confidenceAsk <= c.routing.confidenceContinue
    else {
      throw MiddleAIError.configuration("Routing confidence thresholds are invalid")
    }
    guard ["hybrid", "heuristic"].contains(c.routing.strategy) else {
      throw MiddleAIError.configuration("routing.strategy is invalid")
    }
    guard ["apple", "ollama", "llama_cpp"].contains(c.localLLM.provider),
      c.localLLM.model.count <= 512, (1...30).contains(c.localLLM.timeoutSeconds),
      (1...10).contains(c.localLLM.circuitBreakerFailures),
      (5...600).contains(c.localLLM.circuitBreakerCooldownSeconds)
    else { throw MiddleAIError.configuration("Local LLM settings are invalid") }
    if c.localLLM.enabled, c.localLLM.provider != "apple" {
      guard let endpoint = URL(string: c.localLLM.url), endpoint.scheme == "http",
        endpoint.host?.middleAIIsLoopback == true,
        !c.localLLM.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        throw MiddleAIError.configuration(
          "Local LLM must use a loopback HTTP endpoint and a model ID")
      }
    }
    let ttsProviders = [
      "adaptive", "macos", "supertonic3", "pockettts", "qwen3_tts", "voxtral_tts",
      "local_model",
    ]
    guard ttsProviders.contains(c.tts.provider), c.tts.fallbackProvider == "macos",
      ["high", "fast"].contains(c.tts.quality), c.tts.rate.isFinite,
      (0.5...2).contains(c.tts.rate), c.tts.temperature.isFinite,
      (0...2).contains(c.tts.temperature),
      !c.tts.outputDeviceUID.isEmpty, c.tts.outputDeviceUID.count <= 512,
      (0...2_048).contains(c.tts.cacheMaximumMegabytes),
      c.tts.pronunciationDictionary.count <= 500,
      c.tts.pronunciationDictionary.allSatisfy({ key, value in
        !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          && key.count <= 120 && value.count <= 240
      })
    else {
      throw MiddleAIError.configuration("TTS numeric settings are invalid")
    }
    if c.tts.provider == "local_model",
      c.tts.localCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      throw MiddleAIError.configuration("tts.local_command is required for local_model")
    }
    guard c.stt.model == "parakeet_tdt_v3",
      ["de", "auto"].contains(c.stt.language),
      ["int8", "int4"].contains(c.stt.encoderPrecision),
      ["efficient", "fast"].contains(c.stt.computeMode),
      ["accurate", "fast"].contains(c.stt.longFormMode),
      !c.stt.inputDeviceUID.isEmpty, c.stt.inputDeviceUID.count <= 512,
      (10...600).contains(c.stt.maximumRecordingSeconds)
    else {
      throw MiddleAIError.configuration("STT settings are invalid")
    }
    guard (0...3_650).contains(c.privacy.localCacheRetentionDays) else {
      throw MiddleAIError.configuration(
        "privacy.local_cache_retention_days must be between 0 and 3650")
    }
    guard AppConfig.supportedProfileIDs.contains(c.activeProfile),
      Set(c.profiles.systemPrompts.keys).isSubset(of: Set(AppConfig.supportedProfileIDs)),
      Set(c.profiles.overrides.keys).isSubset(of: Set(AppConfig.supportedProfileIDs)),
      c.profiles.systemPrompts.values.allSatisfy({ $0.count <= 20_000 }),
      c.profiles.overrides.values.allSatisfy({ profile in
        (profile.assistantProvider.map(assistantProviders.contains) ?? true)
          && (profile.model?.count ?? 0) <= 512
          && (profile.ttsVoice?.count ?? 0) <= 512
          && (profile.spokenResponseMode.map {
            ["smart_summary", "full", "first_paragraph"].contains($0)
          } ?? true)
          && (profile.contextBudgetCharacters.map { (4_000...200_000).contains($0) } ?? true)
      })
    else {
      throw MiddleAIError.configuration("Profile configuration is invalid")
    }
    let activationKeys = [
      "left_option", "right_option", "left_control", "right_control", "left_command",
      "right_command", "left_shift", "right_shift",
    ]
    guard activationKeys.contains(c.hotkeys.dictation),
      activationKeys.contains(c.hotkeys.assistant),
      c.hotkeys.dictation != c.hotkeys.assistant
    else { throw MiddleAIError.configuration("Activation keys are invalid") }
    guard ["smart_summary", "full", "first_paragraph"].contains(c.spokenResponseMode),
      (500...10_000).contains(c.spokenResponseThreshold),
      (20...500).contains(c.spokenResponseMaximumWords)
    else { throw MiddleAIError.configuration("Spoken response settings are invalid") }
    let formattingIDs = c.dictation.formattingApplications
    let uniqueFormattingIDs = Set(formattingIDs.map { $0.lowercased() })
    guard formattingIDs.count <= 100, uniqueFormattingIDs.count == formattingIDs.count,
      formattingIDs.allSatisfy({ identifier in
        identifier.count <= 255
          && identifier.range(
            of: #"^[A-Za-z0-9][A-Za-z0-9.-]+$"#, options: .regularExpression) != nil
      })
    else {
      throw MiddleAIError.configuration("Dictation formatting application IDs are invalid")
    }
    guard ["TRACE", "DEBUG", "INFO", "WARNING", "ERROR"].contains(c.logging.level.uppercased())
    else { throw MiddleAIError.configuration("logging.level is invalid") }
  }

  private static func secureExistingPath(_ url: URL, permissions: Int) throws {
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(permissions))], ofItemAtPath: url.path)
  }

  private static func removingComment(from line: String) -> String {
    var quote: Character?
    var escaped = false
    for index in line.indices {
      let character = line[index]
      if escaped {
        escaped = false
        continue
      }
      if character == "\\", quote == "\"" {
        escaped = true
      } else if character == "\"" || character == "'" {
        if quote == character { quote = nil } else if quote == nil { quote = character }
      } else if character == "#", quote == nil {
        return String(line[..<index])
      }
    }
    return line
  }

  private static func snake(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespaces).lowercased()
  }

  private static func unquote(_ value: String) throws -> String {
    guard value.count >= 2 else { return value }
    if value.first == "\"", value.last == "\"" {
      do { return try JSONDecoder().decode(String.self, from: Data(value.utf8)) } catch {
        throw MiddleAIError.configuration("Invalid quoted configuration value")
      }
    }
    if value.first == "'", value.last == "'" { return String(value.dropFirst().dropLast()) }
    return value
  }

  private static func legacyBool(_ value: String, line: Int) throws -> Bool {
    switch value.lowercased() {
    case "true", "yes", "1", "on": return true
    case "false", "no", "0", "off": return false
    default: throw MiddleAIError.configuration("Invalid boolean at line \(line + 1)")
    }
  }
  private static func legacyDouble(_ value: String, line: Int) throws -> Double {
    guard let result = Double(value), result.isFinite else {
      throw MiddleAIError.configuration("Invalid number at line \(line + 1)")
    }
    return result
  }
  private static func legacyInt(_ value: String, line: Int) throws -> Int {
    guard let result = Int(value) else {
      throw MiddleAIError.configuration("Invalid integer at line \(line + 1)")
    }
    return result
  }
}
