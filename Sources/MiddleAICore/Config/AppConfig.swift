import Foundation

public struct AppConfig: Codable, Equatable, Sendable {
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
  }
  public struct Dictation: Codable, Equatable, Sendable {
    public var polishWithLocalAI = true
  }
  public struct Hotkeys: Codable, Equatable, Sendable {
    public var dictation: String
    public var assistant: String

    public init(dictation: String = "left_option", assistant: String = "right_option") {
      self.dictation = dictation
      self.assistant = assistant
    }
  }
  public struct API: Codable, Equatable, Sendable {
    public var bind = "127.0.0.1"
    public var port: UInt16 = 8765
    public var tokenRequired = false
  }
  public struct Logging: Codable, Equatable, Sendable {
    public var level = "INFO"
    public var logPrompts = false
  }
  public var openwebui = OpenWebUI()
  public var routing = Routing()
  public var localLLM = LocalLLM()
  public var tts = TTS()
  public var dictation = Dictation()
  public var hotkeys = Hotkeys()
  public var api = API()
  public var logging = Logging()
  public var spokenResponseMode = "smart_summary"
  public var spokenResponseThreshold = 850
  public var spokenResponseMaximumWords = 110
  public var activeProfile = "default"

  public init() {}
}

public enum ConfigLoader {
  public static var defaultDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".middleai")
  }
  public static var defaultURL: URL { defaultDirectory.appendingPathComponent("config.yaml") }

  public static func load(from url: URL = defaultURL) throws -> AppConfig {
    guard FileManager.default.fileExists(atPath: url.path) else { return AppConfig() }
    let text = try String(contentsOf: url, encoding: .utf8)
    return try parseYAML(text)
  }

  public static func save(_ config: AppConfig, to url: URL = defaultURL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try renderYAML(config).write(to: url, atomically: true, encoding: .utf8)
  }

  public static func parseYAML(_ text: String) throws -> AppConfig {
    var c = AppConfig()
    var section = ""
    for raw in text.components(separatedBy: .newlines) {
      let noComment = raw.split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
      if noComment.trimmingCharacters(in: .whitespaces).isEmpty { continue }
      let indent = noComment.prefix { $0 == " " }.count
      let parts = noComment.trimmingCharacters(in: .whitespaces).split(separator: ":", maxSplits: 1)
        .map(String.init)
      guard !parts.isEmpty else { continue }
      if indent == 0 && parts.count == 1 {
        section = snake(parts[0])
        continue
      }
      guard parts.count == 2 else { continue }
      let key = snake(parts[0])
      let value = unquote(parts[1].trimmingCharacters(in: .whitespaces))
      switch (section, key) {
      case ("openwebui", "url"): c.openwebui.url = value
      case ("openwebui", "auth_method"): c.openwebui.authMethod = value
      case ("openwebui", "username"): c.openwebui.username = value
      case ("openwebui", "model"): c.openwebui.model = value
      case ("openwebui", "tls_verify"): c.openwebui.tlsVerify = bool(value)
      case ("openwebui", "ca_file"): c.openwebui.caFile = value.isEmpty ? nil : value
      case ("routing", "strategy"): c.routing.strategy = value
      case ("routing", "continuation_timeout_seconds"):
        c.routing.continuationTimeoutSeconds = Double(value) ?? c.routing.continuationTimeoutSeconds
      case ("routing", "confidence_continue"):
        c.routing.confidenceContinue = Double(value) ?? c.routing.confidenceContinue
      case ("routing", "confidence_ask"):
        c.routing.confidenceAsk = Double(value) ?? c.routing.confidenceAsk
      case ("local_llm", "enabled"): c.localLLM.enabled = bool(value)
      case ("local_llm", "provider"): c.localLLM.provider = value
      case ("local_llm", "url"): c.localLLM.url = value
      case ("local_llm", "model"): c.localLLM.model = value
      case ("tts", "enabled"): c.tts.enabled = bool(value)
      case ("tts", "provider"): c.tts.provider = value
      case ("tts", "fallback_provider"): c.tts.fallbackProvider = value
      case ("tts", "local_only"): c.tts.localOnly = bool(value)
      case ("tts", "voice"): c.tts.voice = value
      case ("tts", "rate"): c.tts.rate = Float(value) ?? c.tts.rate
      case ("tts", "quality"): c.tts.quality = value
      case ("tts", "temperature"): c.tts.temperature = Float(value) ?? c.tts.temperature
      case ("tts", "local_command"): c.tts.localCommand = value
      case ("dictation", "polish_with_local_ai"):
        c.dictation.polishWithLocalAI = bool(value)
      case ("hotkeys", "dictation"): c.hotkeys.dictation = value
      case ("hotkeys", "assistant"): c.hotkeys.assistant = value
      case ("api", "bind"): c.api.bind = value
      case ("api", "port"): c.api.port = UInt16(value) ?? c.api.port
      case ("api", "token_required"): c.api.tokenRequired = bool(value)
      case ("logging", "level"): c.logging.level = value
      case ("logging", "log_prompts"): c.logging.logPrompts = bool(value)
      case ("spoken_response", "mode"): c.spokenResponseMode = value
      case ("spoken_response", "threshold"):
        c.spokenResponseThreshold = Int(value) ?? c.spokenResponseThreshold
      case ("spoken_response", "maximum_words"):
        c.spokenResponseMaximumWords = Int(value) ?? c.spokenResponseMaximumWords
      case ("profile", "active"): c.activeProfile = value
      default: continue
      }
    }
    guard URL(string: c.openwebui.url)?.scheme != nil else {
      throw MiddleAIError.configuration("openwebui.url is invalid")
    }
    guard c.api.bind == "127.0.0.1" || c.api.bind == "::1" else {
      throw MiddleAIError.configuration("api.bind must be loopback")
    }
    guard c.tts.localOnly else {
      throw MiddleAIError.configuration("MVP requires tts.local_only=true")
    }
    guard c.hotkeys.dictation != c.hotkeys.assistant else {
      throw MiddleAIError.configuration(
        "Diktat und MiddleAI benötigen unterschiedliche Aktivierungstasten.")
    }
    return c
  }

  public static func renderYAML(_ c: AppConfig) -> String {
    """
    openwebui:
      url: "\(c.openwebui.url)"
      auth_method: "\(c.openwebui.authMethod)"
      username: "\(c.openwebui.username)"
      model: "\(c.openwebui.model)"
      tls_verify: \(c.openwebui.tlsVerify)
      ca_file: "\(c.openwebui.caFile ?? "")"
    routing:
      strategy: "\(c.routing.strategy)"
      continuation_timeout_seconds: \(Int(c.routing.continuationTimeoutSeconds))
      confidence_continue: \(c.routing.confidenceContinue)
      confidence_ask: \(c.routing.confidenceAsk)
    local_llm:
      enabled: \(c.localLLM.enabled)
      provider: "\(c.localLLM.provider)"
      url: "\(c.localLLM.url)"
      model: "\(c.localLLM.model)"
    tts:
      enabled: \(c.tts.enabled)
      provider: "\(c.tts.provider)"
      fallback_provider: "macos"
      local_only: true
      voice: "\(c.tts.voice)"
      rate: \(c.tts.rate)
      quality: "\(c.tts.quality)"
      temperature: \(c.tts.temperature)
      local_command: "\(c.tts.localCommand)"
    dictation:
      polish_with_local_ai: \(c.dictation.polishWithLocalAI)
    hotkeys:
      dictation: "\(c.hotkeys.dictation)"
      assistant: "\(c.hotkeys.assistant)"
    spoken_response:
      mode: "\(c.spokenResponseMode)"
      threshold: \(c.spokenResponseThreshold)
      maximum_words: \(c.spokenResponseMaximumWords)
    api:
      bind: "\(c.api.bind)"
      port: \(c.api.port)
      token_required: \(c.api.tokenRequired)
    logging:
      level: "\(c.logging.level)"
      log_prompts: \(c.logging.logPrompts)
    profile:
      active: "\(c.activeProfile)"
    """
  }

  private static func snake(_ s: String) -> String {
    s.trimmingCharacters(in: .whitespaces).lowercased()
  }
  private static func unquote(_ s: String) -> String {
    s.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
  }
  private static func bool(_ s: String) -> Bool {
    ["true", "yes", "1", "on"].contains(s.lowercased())
  }
}
