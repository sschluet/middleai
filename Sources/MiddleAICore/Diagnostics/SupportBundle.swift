import Foundation

public struct SupportBundleEnvironment: Sendable {
  public var appVersion: String
  public var operatingSystem: String
  public var architecture: String
  public var assistantProvider: String
  public var ttsProvider: String
  public var activeProfile: String
  public var privateSession: Bool

  public init(
    appVersion: String, operatingSystem: String, architecture: String,
    assistantProvider: String, ttsProvider: String, activeProfile: String,
    privateSession: Bool
  ) {
    self.appVersion = appVersion
    self.operatingSystem = operatingSystem
    self.architecture = architecture
    self.assistantProvider = assistantProvider
    self.ttsProvider = ttsProvider
    self.activeProfile = activeProfile
    self.privateSession = privateSession
  }
}

public enum SupportBundleBuilder {
  /// Produces a deliberately small report from allow-listed runtime metadata. Failed diagnostic
  /// details are omitted because network errors can contain URLs, account names or server output.
  public static func report(
    environment: SupportBundleEnvironment, checks: [DiagnosticCheck],
    localModelStates: [(name: String, state: String, size: String)]
  ) -> String {
    let checkLines = checks.map { check in
      let status = check.passed ? "OK" : "FEHLER"
      let safeName = safeLabel(check.name)
      let detail = check.passed ? check.detail.flatMap(safeSuccessfulDetail) : nil
      return "- \(status) \(safeName)" + (detail.map { ": \($0)" } ?? "")
    }.joined(separator: "\n")
    let modelLines = localModelStates.map {
      "- \(safeLabel($0.name)): \(safeLabel($0.state)) · \(safeLabel($0.size))"
    }.joined(separator: "\n")
    return """
      MiddleAI Supportbericht
      Version: \(safeLabel(environment.appVersion))
      macOS: \(safeLabel(environment.operatingSystem))
      Architektur: \(safeLabel(environment.architecture))
      Antwortanbieter: \(safeLabel(environment.assistantProvider))
      TTS-Provider: \(safeLabel(environment.ttsProvider))
      Profil: \(safeLabel(environment.activeProfile))
      Private Sitzung: \(environment.privateSession ? "aktiv" : "inaktiv")

      Prüfungen:
      \(checkLines.isEmpty ? "- Noch nicht ausgeführt" : checkLines)

      Lokale Modelle:
      \(modelLines.isEmpty ? "- Keine Statusdaten" : modelLines)

      Datenschutz: Der Bericht enthält keine Zugangsdaten, Serveradressen, Dateipfade,
      Modell-IDs, Benutzernamen, Diktate, Prompts, Antworten oder Gesprächsinhalte.
      """
  }

  public static func safeSuccessfulDetail(_ value: String) -> String? {
    let allowedPatterns = [
      #"^Freigegeben$"#, #"^TLS oder lokaler Loopback$"#, #"^Bearer-Token erforderlich$"#,
      #"^Modell verfügbar$"#, #"^[0-9]+ Modelle verfügbar$"#,
      #"^[0-9]+(?:[.,][0-9]+)? GB verfügbar$"#, #"^[0-7]{3}; erwartet [0-7]{3}$"#,
      #"^Noch nicht angelegt$"#, #"^Native macOS fallback remains available$"#,
    ]
    guard
      allowedPatterns.contains(where: { value.range(of: $0, options: .regularExpression) != nil })
    else { return nil }
    return safeLabel(value)
  }

  private static func safeLabel(_ value: String) -> String {
    let scalars = value.unicodeScalars.filter {
      !CharacterSet.controlCharacters.contains($0) && $0.value != 0x2028 && $0.value != 0x2029
    }
    return String(String.UnicodeScalarView(scalars)).prefix(160).description
  }
}

public enum OfflineReadinessState: String, Sendable {
  case ready
  case needsDownload
  case needsService
  case requiresNetwork
}

public struct OfflineReadinessItem: Sendable {
  public let title: String
  public let state: OfflineReadinessState
  public let detail: String

  public init(title: String, state: OfflineReadinessState, detail: String) {
    self.title = title
    self.state = state
    self.detail = detail
  }
}
