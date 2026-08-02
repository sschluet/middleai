import Foundation
import MiddleAICore

@main struct MiddleAICLI {
  @MainActor static func main() async {
    do {
      var config = try ConfigLoader.load()
      let args = Array(CommandLine.arguments.dropFirst())
      guard let command = args.first else {
        usage()
        return
      }
      if command == "configure" {
        try ConfigLoader.save(config)
        print("Created \(ConfigLoader.defaultURL.path). Edit it or use the app Settings window.")
        return
      }
      if command == "status" {
        let store = try SQLiteConversationStore(
          path: ConfigLoader.defaultDirectory.appendingPathComponent("middleai.sqlite").path)
        let currentID = try store.setting(key: "current_conversation_id")
        let current = try currentID.flatMap { try store.conversation(id: $0) }
        print("MiddleAI configuration: \(ConfigLoader.defaultURL.path)")
        print("Current conversation: \(current?.title ?? "none")")
        print(
          "TTS: \(config.tts.enabled ? "enabled, local \(config.tts.provider) / \(config.tts.voice)" : "disabled")"
        )
        return
      }
      if command == "tts-use-pocket" {
        config.tts.enabled = true
        config.tts.provider = "pockettts"
        config.tts.fallbackProvider = "macos"
        config.tts.localOnly = true
        config.tts.voice = "anna"
        config.tts.quality = "high"
        config.tts.temperature = 0.65
        try ConfigLoader.save(config)
        print("PocketTTS German 24L with the female Anna voice is now the local TTS provider.")
        return
      }
      if command == "tts-use-supertonic" {
        config.tts.enabled = true
        config.tts.provider = "supertonic3"
        config.tts.fallbackProvider = "macos"
        config.tts.localOnly = true
        config.tts.voice = "F1"
        config.tts.quality = "high"
        config.tts.rate = 1.0
        try ConfigLoader.save(config)
        print("Supertonic 3 with the female F1 voice is now the local German TTS provider.")
        return
      }
      let credentials = CompositeCredentialStore()
      let engine = try MiddleAIFactory.make(config: config, credentials: credentials)
      switch command {
      case "ask":
        guard args.count > 1 else {
          throw MiddleAIError.configuration("Usage: middleai ask \"text\"")
        }
        try await engine.client.authenticate()
        printResult(
          try await engine.handle(text: args.dropFirst().joined(separator: " "), source: "cli"))
      case "status": break
      case "new": printResult(try await engine.handle(text: "Neuer Chat", source: "cli"))
      case "stop": printResult(try await engine.handle(text: "Stopp", source: "cli"))
      case "conversations":
        for c in try engine.manager.list() {
          print("\(c.id)\t\(c.title)\t\(c.lastUsedAt.formatted())")
        }
      case "doctor":
        let checks = await Doctor().run(
          config: config, credentials: credentials, client: engine.client)
        for check in checks {
          print("\(check.passed ? "✓":"⚠") \(check.name)\(check.detail.map{" — \($0)"} ?? "")")
        }
      case "tts-prepare":
        print("Preparing \(config.tts.provider) voice model locally…")
        try await engine.ttsQueue.prepare()
        print("Local TTS model is ready.")
      case "tts-test":
        let sample = TTSVoiceCatalog.germanSample
        let requestedProvider = args.dropFirst().first?.lowercased() ?? config.tts.provider.lowercased()
        let requestedVoice = requestedProvider == "voxtral_tts" ? "de_female" : config.tts.voice
        let provider: any TTSProvider
        switch requestedProvider {
        case "qwen3_tts":
          provider = VoxtralTTSProvider.qwen(
            voice: requestedVoice, rate: config.tts.rate)
        case "voxtral_tts":
          provider = VoxtralTTSProvider(voice: requestedVoice)
        case "supertonic3":
          provider = Supertonic3TTSProvider(
            voice: config.tts.voice, rate: config.tts.rate,
            highQuality: config.tts.quality.lowercased() != "fast")
        case "pockettts":
          provider = PocketTTSProvider(
            voice: config.tts.voice,
            highQuality: config.tts.quality.lowercased() != "fast",
            temperature: config.tts.temperature)
        case "local_model":
          provider = LocalModelTTSProvider(executable: config.tts.localCommand)
        default:
          provider = MacOSTTSProvider(voice: config.tts.voice, rate: config.tts.rate)
        }
        print("Testing local \(requestedProvider) speech output…")
        try await provider.prepare()
        try await provider.speak(sample)
        print("Local \(requestedProvider) synthesis and playback succeeded.")
      case "tts-render":
        let sample = TTSVoiceCatalog.germanSample
        let destination = args.dropFirst().first.map(URL.init(fileURLWithPath:))
          ?? ConfigLoader.defaultDirectory.appendingPathComponent("tts-test.wav")
        try FileManager.default.createDirectory(
          at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let audio: Data
        switch config.tts.provider.lowercased() {
        case "supertonic3":
          let provider = Supertonic3TTSProvider(
            voice: config.tts.voice, rate: config.tts.rate,
            highQuality: config.tts.quality.lowercased() != "fast")
          audio = try await provider.render(sample)
        case "pockettts":
          let provider = PocketTTSProvider(
            voice: config.tts.voice,
            highQuality: config.tts.quality.lowercased() != "fast",
            temperature: config.tts.temperature)
          audio = try await provider.render(sample)
        default:
          throw MiddleAIError.configuration(
            "tts-render supports the local supertonic3 and pockettts providers")
        }
        try audio.write(to: destination, options: .atomic)
        print("Rendered \(audio.count) bytes of local \(config.tts.provider) audio to \(destination.path)")
      case "serve":
        try await engine.client.authenticate()
        let server = LocalInputServer(engine: engine, config: config.api, credentials: credentials)
        try server.start()
        print("MiddleAI listening on http://\(config.api.bind):\(config.api.port)")
        await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
      case "configure": break
      default: usage()
      }
    } catch {
      FileHandle.standardError.write(Data("MiddleAI: \(error.localizedDescription)\n".utf8))
      exit(1)
    }
  }
  static func printResult(_ result: InputResult) {
    switch result {
    case .response(let value, _), .local(let value), .clarification(let value): print(value)
    }
  }
  static func usage() {
    print(
      "Usage: middleai <ask|status|new|stop|conversations|doctor|tts-use-supertonic|tts-use-pocket|tts-prepare|tts-render|tts-test|serve|configure> [text]"
    )
  }
}
