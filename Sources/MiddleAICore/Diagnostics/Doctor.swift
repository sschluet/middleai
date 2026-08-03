import AVFoundation
import ApplicationServices
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
    config: AppConfig, credentials: any CredentialStore, client: any AssistantClientProtocol
  ) async -> [DiagnosticCheck] {
    var checks: [DiagnosticCheck] = []
    checks.append(
      DiagnosticCheck(
        "Configuration", (try? ConfigLoader.parseYAML(ConfigLoader.renderYAML(config))) != nil))
    let diagnosticDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "middleai-doctor-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: diagnosticDirectory) }
    let dbPath = diagnosticDirectory.appendingPathComponent("doctor.sqlite").path
    checks.append(DiagnosticCheck("SQLite", (try? SQLiteConversationStore(path: dbPath)) != nil))
    checks.append(permissionCheck(for: ConfigLoader.defaultDirectory, expected: 0o700))
    if FileManager.default.fileExists(atPath: ConfigLoader.defaultURL.path) {
      checks.append(permissionCheck(for: ConfigLoader.defaultURL, expected: 0o600))
    }
    checks.append(
      DiagnosticCheck(
        "Mikrofonberechtigung",
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
        microphonePermissionDescription))
    checks.append(
      DiagnosticCheck(
        "Bedienungshilfen", AXIsProcessTrusted(),
        AXIsProcessTrusted() ? "Freigegeben" : "In den macOS-Systemeinstellungen freigeben"))
    checks.append(
      DiagnosticCheck(
        "Eingabeüberwachung", CGPreflightListenEventAccess(),
        CGPreflightListenEventAccess()
          ? "Freigegeben" : "In den macOS-Systemeinstellungen freigeben"))
    if let values = try? ConfigLoader.defaultDirectory.resourceValues(forKeys: [
      .volumeAvailableCapacityForImportantUsageKey
    ]), let free = values.volumeAvailableCapacityForImportantUsage {
      let gigabytes = Double(free) / 1_000_000_000
      checks.append(
        DiagnosticCheck(
          "Freier Speicher", gigabytes >= 5,
          String(format: "%.1f GB verfügbar", gigabytes)))
    }
    if config.assistant.provider == "openwebui" {
      let endpoint = URL(string: config.openwebui.url)
      let secureEndpoint =
        endpoint?.scheme?.lowercased() == "https" || endpoint?.host?.isLoopback == true
      checks.append(
        DiagnosticCheck(
          "Sicherer OpenWebUI-Endpunkt", secureEndpoint,
          secureEndpoint ? "TLS oder lokaler Loopback" : "Für entfernte Server HTTPS verwenden"))
    }
    let credentialAvailable: Bool
    if config.assistant.provider == "openai" {
      credentialAvailable =
        (try? credentials.read(account: HostedAIProvider.openai.credentialAccount)) != nil
    } else if config.assistant.provider == "openrouter" {
      credentialAvailable =
        (try? credentials.read(account: HostedAIProvider.openrouter.credentialAccount)) != nil
    } else {
      let scopedCredentials = ScopedCredentialStore(
        base: credentials, baseURL: config.openwebui.url, profile: config.activeProfile)
      credentialAvailable =
        (try? scopedCredentials.read(
          account: config.openwebui.authMethod == "api_key" ? "api_token" : "password")) != nil
    }
    checks.append(
      DiagnosticCheck(
        "Schlüsselbund / Zugangsdaten", credentialAvailable))
    do {
      try await client.health()
      checks.append(DiagnosticCheck("\(config.assistantProviderTitle) erreichbar", true))
    } catch {
      checks.append(
        DiagnosticCheck(
          "\(config.assistantProviderTitle) erreichbar", false, error.localizedDescription))
      return checks
    }
    do {
      try await client.authenticate()
      checks.append(DiagnosticCheck("Authentication", true))
      let models = try await client.models()
      checks.append(DiagnosticCheck("Anbieter-API", true, "\(models.count) Modelle verfügbar"))
      let configuredModel = config.assistantModel.trimmingCharacters(in: .whitespacesAndNewlines)
      checks.append(
        DiagnosticCheck(
          "Konfigurierte Modell-ID", !configuredModel.isEmpty && models.contains(configuredModel),
          configuredModel.isEmpty
            ? "Keine Modell-ID ausgewählt"
            : (models.contains(configuredModel) ? "Modell verfügbar" : "Modell nicht gefunden")))
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
    checks.append(
      DiagnosticCheck(
        "Lokale API-Authentifizierung", config.api.tokenRequired,
        config.api.tokenRequired
          ? "Bearer-Token erforderlich" : "Nicht aktiv; jeder lokale Prozess kann Anfragen senden"))
    return checks
  }

  private var microphonePermissionDescription: String {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: return "Freigegeben"
    case .notDetermined: return "Noch nicht angefragt"
    case .denied: return "Abgelehnt"
    case .restricted: return "Durch Systemrichtlinie eingeschränkt"
    @unknown default: return "Unbekannter Status"
    }
  }

  private func permissionCheck(for url: URL, expected: Int) -> DiagnosticCheck {
    guard FileManager.default.fileExists(atPath: url.path) else {
      return DiagnosticCheck("Dateirechte \(url.lastPathComponent)", true, "Noch nicht angelegt")
    }
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    let permissions = (attributes?[.posixPermissions] as? NSNumber)?.intValue
    return DiagnosticCheck(
      "Dateirechte \(url.lastPathComponent)", permissions == expected,
      permissions.map { String(format: "%03o; erwartet %03o", $0, expected) }
        ?? "Nicht lesbar")
  }
}

extension String {
  fileprivate var isLoopback: Bool {
    let normalized = lowercased()
    return normalized == "localhost" || normalized == "127.0.0.1" || normalized == "::1"
  }
}
