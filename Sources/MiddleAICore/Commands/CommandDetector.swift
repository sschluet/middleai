import Foundation

public enum LocalCommand: Equatable, Sendable {
  case newConversation
  case previousConversation
  case topic(String)
  case stop
  case disableSpeech
  case enableSpeech
  case currentConversation
  case switchProfile(String)
}

public struct CommandDetector: Sendable {
  public init() {}
  public func detect(_ text: String) -> LocalCommand? {
    let normalized = text.folding(
      options: [.diacriticInsensitive, .caseInsensitive], locale: .current
    )
    .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    .trimmingCharacters(in: .punctuationCharacters)
    switch normalized {
    case "neues thema", "neuer chat", "new topic", "new chat": return .newConversation
    case "zuruck zum letzten thema", "zuruck zum vorherigen chat", "previous chat":
      return .previousConversation
    case "stop", "stopp", "hor auf", "stop speaking": return .stop
    case "nicht vorlesen", "sprache aus", "mute": return .disableSpeech
    case "vorlesen einschalten", "sprache ein", "unmute": return .enableSpeech
    case "welcher chat ist gerade aktiv", "welches thema ist gerade aktiv", "current chat":
      return .currentConversation
    case "architekturmodus", "architecture mode": return .switchProfile("architecture")
    case "codingmodus", "coding mode": return .switchProfile("coding")
    case "managementmodus", "management mode": return .switchProfile("management")
    case "recherchemodus", "research mode": return .switchProfile("research")
    case "standardmodus", "default mode": return .switchProfile("default")
    default:
      for prefix in ["zuruck zum ", "zurück zum "] where normalized.hasPrefix(prefix) {
        return .topic(
          String(normalized.dropFirst(prefix.count)).replacingOccurrences(of: "-thema", with: ""))
      }
      return nil
    }
  }
}
