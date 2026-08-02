import AVFoundation
import Foundation

public struct DiagnosticCheck: Sendable {
  public let name: String
  public let passed: Bool
  public let detail: String?
  public init(_ name: String, _ passed: Bool, _ detail: String? = nil) {
    self.name = name
    self.passed = passed
    self.detail = detail
  }
}
public struct Doctor: Sendable {
  public init() {}
  public func run(
    config: AppConfig, credentials: any CredentialStore, client: any OpenWebUIClientProtocol
  ) async -> [DiagnosticCheck] {
    var checks: [DiagnosticCheck] = []
    checks.append(
      DiagnosticCheck(
        "Configuration", (try? ConfigLoader.parseYAML(ConfigLoader.renderYAML(config))) != nil))
    let dbPath = ConfigLoader.defaultDirectory.appendingPathComponent("doctor.sqlite").path
    checks.append(DiagnosticCheck("SQLite", (try? SQLiteConversationStore(path: dbPath)) != nil))
    checks.append(
      DiagnosticCheck(
        "Keychain / credential",
        (try? credentials.read(
          account: config.openwebui.authMethod == "api_key" ? "api_token" : "password")) != nil))
    do {
      try await client.health()
      checks.append(DiagnosticCheck("Open WebUI reachable", true))
    } catch {
      checks.append(DiagnosticCheck("Open WebUI reachable", false, error.localizedDescription))
      return checks
    }
    do {
      try await client.authenticate()
      checks.append(DiagnosticCheck("Authentication", true))
      _ = try await client.models()
      checks.append(DiagnosticCheck("Open WebUI API", true))
    } catch {
      checks.append(DiagnosticCheck("Authentication / API", false, error.localizedDescription))
    }
    checks.append(DiagnosticCheck("macOS TTS", !AVSpeechSynthesisVoice.speechVoices().isEmpty))
    if config.tts.provider == "local_model" {
      checks.append(
        DiagnosticCheck(
          "Local TTS model", FileManager.default.isExecutableFile(atPath: config.tts.localCommand),
          "Native macOS fallback remains available"))
    }
    checks.append(
      DiagnosticCheck(
        "HTTP listener binding", config.api.bind == "127.0.0.1" || config.api.bind == "::1",
        "\(config.api.bind):\(config.api.port)"))
    return checks
  }
}
