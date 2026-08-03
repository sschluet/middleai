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

    public init(dictation: String = "left_option", assistant: String = "right_option") {
      self.dictation = dictation
      self.assistant = assistant
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
    public var level = "INFO"
    public var logPrompts = false
  }
  public struct Privacy: Codable, Equatable, Sendable {
    /// Number of days to retain MiddleAI's local routing copy. Zero keeps it indefinitely.
    public var localCacheRetentionDays = 90
  }
  public var openwebui = OpenWebUI()
  public var routing = Routing()
  public var localLLM = LocalLLM()
  public var tts = TTS()
  public var dictation = Dictation()
  public var hotkeys = Hotkeys()
  public var api = API()
  public var logging = Logging()
  public var privacy = Privacy()
  public var spokenResponseMode = "smart_summary"
  public var spokenResponseThreshold = 850
  public var spokenResponseMaximumWords = 110
  public var activeProfile = "default"

  public init() {}
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
    guard let webURL = URL(string: c.openwebui.url), ["http", "https"].contains(webURL.scheme),
      webURL.user == nil, webURL.password == nil
    else {
      throw MiddleAIError.configuration("openwebui.url must be an HTTP or HTTPS URL")
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
    guard c.hotkeys.dictation != c.hotkeys.assistant else {
      throw MiddleAIError.configuration(
        "Diktat und MiddleAI benötigen unterschiedliche Aktivierungstasten.")
    }
    guard (0...1).contains(c.routing.confidenceAsk),
      (0...1).contains(c.routing.confidenceContinue),
      c.routing.continuationTimeoutSeconds.isFinite,
      c.routing.continuationTimeoutSeconds > 0,
      c.routing.confidenceAsk <= c.routing.confidenceContinue
    else {
      throw MiddleAIError.configuration("Routing confidence thresholds are invalid")
    }
    guard c.tts.rate.isFinite, c.tts.rate > 0, c.tts.temperature.isFinite else {
      throw MiddleAIError.configuration("TTS numeric settings are invalid")
    }
    guard (0...3_650).contains(c.privacy.localCacheRetentionDays) else {
      throw MiddleAIError.configuration(
        "privacy.local_cache_retention_days must be between 0 and 3650")
    }
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
