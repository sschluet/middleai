import Foundation

public struct ProfileStore: Sendable {
  public var profiles: [String: Profile]
  public init(
    profiles: [String: Profile] = [
      "default": Profile(name: "default"),
      "management": Profile(name: "management"),
      "architecture": Profile(
        name: "architecture",
        systemPrompt: "Du bist ein Enterprise-IT-Architekt. Antworte technisch präzise."),
      "coding": Profile(name: "coding"),
      "research": Profile(name: "research"),
    ]
  ) { self.profiles = profiles }

  public static func load(from url: URL) -> ProfileStore {
    guard let text = try? String(contentsOf: url) else { return ProfileStore() }
    var store = ProfileStore()
    var current: String?
    for raw in text.components(separatedBy: .newlines) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if raw.hasPrefix("  "), !raw.hasPrefix("    "), line.hasSuffix(":") {
        current = String(line.dropLast())
        store.profiles[current!] = Profile(name: current!)
      } else if raw.hasPrefix("    "), let current, let colon = line.firstIndex(of: ":") {
        let key = String(line[..<colon])
        let value = String(line[line.index(after: colon)...]).trimmingCharacters(
          in: CharacterSet(charactersIn: " \"'"))
        if key == "model" { store.profiles[current]?.model = value }
        if key == "tts_voice" { store.profiles[current]?.ttsVoice = value }
      }
    }
    return store
  }
}
